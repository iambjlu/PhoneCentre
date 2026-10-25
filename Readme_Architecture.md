# PhoneCentre 架構說明

macOS（SwiftUI + AppKit）的 Android 手機中心。透過 adb 連線手機，用 scrcpy-server 做畫面鏡像與遠端操作，
另外提供檔案管理、相機膠卷、啟動台、選單列快速取用，以及讓其他 PhoneCentre 加密連入。

- 建置：`scripts/build.sh`（輸出 `build/PhoneCentre.app`；加 `--install` 會複製到 /Applications）
- 只需要這個 `.app`：scrcpy-server 與手機端輔助程式都打包在裡面；adb 找不到時 App 會協助從 Google 官方下載
- 最低系統：macOS 14

## 目錄

```
Package.swift                  SwiftPM 專案（單一 executable target，Swift 5 語言模式）
scripts/build.sh               建置腳本：下載並驗證 scrcpy-server、建置 Android 輔助程式、編譯、組裝 .app、簽章
scripts/make_icon.swift        產生 Resources/AppIcon.icns
Resources/Info.plist           App 的 Info.plist（含區域網路權限說明、Bonjour 服務）
Resources/phonecentre-helper.jar  已建置好的 Android 輔助程式（沒有 Android SDK 時直接使用）
AndroidHelper/                 Android 輔助程式原始碼（Java，d8 轉 dex，在手機以 app_process 執行）
ThirdParty/scrcpy/scrcpy-server  官方 scrcpy-server v3.3.4（Apache-2.0，未修改）
ThirdParty/NOTICE.md、licenses/  第三方授權聲明（會一起複製進 .app）
Sources/PhoneCentre/           Swift 原始碼（下面各章節）
```

## scripts/build.sh

1. 確認 `ThirdParty/scrcpy/scrcpy-server` 的 SHA256，不符就從 GitHub release 下載 v3.3.4。
2. 有 Android SDK 且 Java 原始碼比 jar 新時，用 javac（`-source 8`）＋ d8（`--min-api 26`）重建 `Resources/phonecentre-helper.jar`；沒有 SDK 就用已提交的 jar。
3. 沒有 `Resources/AppIcon.icns` 時執行 `make_icon.swift` 產生。
4. `swift build -c release --arch arm64`，組裝 `.app`（執行檔、Info.plist、圖示、輔助程式 jar、scrcpy-server、授權聲明）。
5. 簽章：優先用鑰匙圈中的「Apple Development」憑證（簽章固定，重新編譯後不必重新允許區域網路權限與鑰匙圈存取），可用環境變數 `PHONECENTRE_SIGN` 指定；都沒有就用 ad-hoc。

## AndroidHelper（手機端輔助程式）

`com.phonecentre.helper.Main`，以 shell 身分執行：
`CLASSPATH=/data/local/tmp/phonecentre-helper.jar app_process / com.phonecentre.helper.Main <cmd>`

- `list`：列出有啟動器入口的 App，每行「套件 \t 名稱 \t 是否系統 App」。
- `icons <px> <套件...>`：每行「套件 \t base64 PNG」。
- `thumbs <px> <路徑...>`：在手機端產生相片／影片縮圖，每行「路徑 \t base64 JPEG」，只傳小圖不傳原檔。
  - 圖片用 `ThumbnailUtils`（API 29+），影片用 `ThumbnailUtils`／`MediaMetadataRetriever`，再不行用 `BitmapFactory` 取樣。
  - 方向修正：HEIC 的旋轉寫在 HEIF 容器（irot），用 `MediaMetadataRetriever.METADATA_KEY_IMAGE_ROTATION` 讀；其他用 EXIF。比對原圖與縮圖長寬，避免已轉過的再轉一次。
- 所有指令都會先透過 `ActivityThread.systemMain().getSystemContext()` 取得系統 Context（三星的 `MediaMetadataRetriever` 內部也需要），失敗時名稱與圖示改用 `AssetManager.addAssetPath` 直接讀 APK 資源。

## Sources/PhoneCentre/App

### main.swift
在 MainActor 上建立 `NSApplication` 與 `AppDelegate` 並執行。

### AppDelegate.swift
- 一般模式：啟動 `CacheManager`、`DeviceManager`（輪詢與自動維持連線）、`RemoteManager`、`ShareServer`、選單列，並開啟主視窗。關閉所有視窗後仍留在選單列（關掉選單列圖示時才會結束）。
- 子程序模式（`ChildMode.isChild`）：只開一個鏡像／App 視窗，視窗關閉就結束。
- 建立主選單（設定 ⌘,、顯示手機中心 ⌘0、編輯、視窗）。

### AppSettings.swift
- `SettingsData`：所有可同步的設定（Codable）。讀檔時以預設值補齊缺少的欄位，舊設定檔也能讀。
- `AppSettings`：`@dynamicMemberLookup`，`settings.keepAlive` 直接讀寫 `data.keepAlive`；SwiftUI 綁定用 `$settings.data.xxx`。
- 儲存位置：預設在 UserDefaults suite `com.iambjlu.PhoneCentre.shared`（固定 suite，Dock 獨立視窗的子程序 bundle id 不同也讀得到）；可在設定選一個資料夾（例如 iCloud Drive），設定寫進該資料夾的 `settings.json`，每 3 秒偵測其他電腦改過的檔案並重新載入。資料夾路徑與自訂 adb 路徑只存在本機。
- 密碼（手機解鎖密碼、分享密碼、遠端主機密碼）存在鑰匙圈；開啟「密碼也存到這個資料夾」時另外以明碼寫入 `settings.json` 的 `secrets`，另一台 Mac 讀到後會存回自己的鑰匙圈。
- 列舉：`DockMode`（共用／每個視窗各自一個 Dock 圖示）、`AppLaunchTarget`（主螢幕／獨立視窗）、`KeyboardMode`（實體按鍵／Mac 輸入法）、`CacheClearPolicy`（斷線清除／幾天沒連線清除／只依容量）。
- `VideoOptions`：FPS、bitrate、最大解析度；可依裝置（`CacheManager.key`）個別覆寫。

### WindowManager.swift
開啟鏡像相關視窗，依 Dock 設定決定在本程序開，或交給 `DockLauncher` 以子程序開。
- `openMirror`：主螢幕鏡像。
- `openApp(device, package, at:)`：在虛擬顯示器上執行單一 App；`at` 是視窗左上角位置（從 App 列拖出來放開的地方）。
- `openDesktop`：桌面模式（橫向虛擬顯示器＋系統裝飾）。
- `launch`：依啟動台的「開啟方式」選擇獨立視窗或主螢幕。

### DockLauncher.swift
- `ChildMode`：解析子程序參數（`--child --serial --host --port [--remote] [--package --label] [--desktop] [--icon] [--at x,y]`）。子程序會設定 Dock 圖示、開啟視窗，並在背景載入 App 清單（給 App 列與標題用）。
- `DockLauncher`：在 `~/Library/Application Support/PhoneCentre/Launchers/` 用 APFS clone（`cp -c`）複製一份 .app，改 `CFBundleIdentifier`／`CFBundleName` 後 ad-hoc 重新簽章，再以 `NSWorkspace.openApplication` 帶參數啟動；同一個鍵（裝置＋App）已在執行就直接切過去。主程式更新後副本會重建。

### MainView.swift
主視窗：`NavigationSplitView`。
- 側邊欄：本機裝置、記住但目前離線的無線裝置（右鍵可立即重連或忘記）、各遠端 PhoneCentre 的裝置；底部顯示 adb server 狀態與最近事件。
- 內容：分頁「總覽／啟動台／檔案／相機膠卷」；找不到 adb 時顯示 `AdbSetupView`（一鍵下載 Google Platform-Tools）。

### AddDeviceSheet.swift
- 無線 ADB：`adb connect`、Android 11+ 的配對（`adb pair`）、`adb mdns services` 找到的裝置。
- 遠端 PhoneCentre：新增主機（名稱、主機、port、密碼）、Bonjour（`_phonecentre._tcp`）瀏覽區域網路上的 PhoneCentre、管理已加入的主機。

### DeviceOverview.swift
裝置總覽：鏡像畫面、桌面模式(Beta)、安裝 APK、設定解鎖密碼、裝置資訊（型號、Android 版本、螢幕、電池、儲存空間、序號）、拖放區（APK 安裝；照片影片存相機膠卷；其他存 Download），以及 DeX 的說明。

## Sources/PhoneCentre/ADB

### AdbLocator.swift
尋找 adb：自訂路徑 → PhoneCentre 下載的 → `$ANDROID_HOME` → `~/Library/Android/sdk` → Homebrew → PATH。
找不到時 `install()` 從 `dl.google.com` 下載 platform-tools，以 `ditto` 解壓到 `~/Library/Application Support/PhoneCentre/platform-tools` 並移除隔離屬性。adb 不隨 App 散布（Android SDK 授權條款）。

### AdbSocket.swift
直接走 adb server 協定的阻塞式 socket（`AdbEndpoint` 可以是本機 5037，或遠端通道映射出來的本機 port）。
- `hostQuery`：`host:devices-l`、`host:connect:` 等。
- `open`：`host:transport:<serial>` 後開啟服務（`exec:`、`shell:`、`localabstract:`），不需要 `adb forward`，所以遠端裝置也能用。

### AdbClient.swift
- 短指令走 socket 的 `exec:`（不開程序、二進位安全）。
- push／pull／install／pair／mdns 走 adb CLI（遠端端點加 `-H -P`）。push 後發送媒體掃描廣播。

### Device.swift
`Device`（serial、狀態、型號、端點，id 遠端為 `<remoteID>|serial`）與 `DeviceInfo`（裝置名稱、廠牌、型號、Android 版本、SDK、ro.serialno、螢幕大小、密度）。

### DeviceManager.swift
每 2 秒輪詢所有端點的 `host:devices-l`。
- 自動維持連線：本機 adb server 連不上（例如被其他程式砍掉）時自動 `adb start-server`；記住的無線裝置斷線時以指數退避重連（最長 60 秒）；連不上時用 `adb mdns services` 依 ro.serialno 找出新的無線偵錯 port 並更新紀錄。
- 記住連線過的無線裝置（同一支手機換 port 會更新舊紀錄）。
- 裝置清單變動時通知 `CacheManager`。

### AppCatalog.swift
一台裝置的 App 清單、圖示（存在 `CacheManager` 的 icons 目錄）、已開啟與最近使用的 App。
- 已開啟／最近：解析 `dumpsys activity recents` 的每個「Recent #N」區塊，取 `realActivity`／`cmp=` 的套件名；找不到時以 affinity 對已安裝套件做前綴比對（例如 `com.android.settings.root` → `com.android.settings`）；排除桌面、最近使用畫面。程序還在（`ps -A`）的算「已開啟」。
- 啟動、強制停止、解除安裝、開啟 App 資訊。
- `icon(for:)` 在 view body 中呼叫也安全（不會同步修改 @Published）。

### HelperTool.swift
推送（大小不同時才推）並執行手機端輔助程式，參數會做 shell 跳脫。

## Sources/PhoneCentre/Mirror

### ScrcpySession.swift
一次 scrcpy-server 連線。
- 推送 server（每次啟動 server 會刪除自己，所以大小不同就重推），以 `shell:` 服務啟動。三星部分機型用 `exec:` 啟動會讓 server 原生崩潰。
- 參數只送與預設值不同的部分，並把 app_process 參數長度壓在 240 字元內：三星 S10（Android 12）的 `libstagefright`（`ACodec::reconfigEncoder4OtherApps`）會把程序 cmdline 讀進固定大小緩衝區，超過約 257 字元就 stack corruption 崩潰。超過時從最不重要的參數開始捨棄。
- 依序連線 video（先讀 1 byte dummy）→ audio → control 三條 `localabstract:scrcpy_<scid>` socket；讀裝置名稱與 codec meta 後進入封包迴圈（12 byte header：pts＋config/keyframe 旗標、大小）。
- 音訊：raw PCM。手機靜音選項：預設 `output`（REMOTE_SUBMIX，手機不發聲）；關閉時在 Android 13+ 用 `playback`＋`audio_dup`。
- 控制：剪貼簿（含 Mac→手機的 sequence）、手機訊息讀取（剪貼簿、ack、uhid）。
- 虛擬顯示器：`new_display=WxH/dpi`、`vd_destroy_content=false`（關閉視窗時 App 回到手機主螢幕），單一 App 視窗關閉系統裝飾。

### ControlMessage.swift
scrcpy 3.3.4 控制協定編碼（big-endian）：按鍵、文字、觸控、捲動、返回／點亮、通知欄、剪貼簿、面板電源、旋轉、啟動 App、重設影像。

### VideoDecoder.swift
H.264 Annex B → AVCC，config 封包取 SPS/PPS 建立 `CMVideoFormatDescription`，畫面大小改變時回報；產生 `CMSampleBuffer` 交給 `AVSampleBufferDisplayLayer` 硬體解碼。

### AudioPlayer.swift
`AVAudioEngine`＋`AVAudioSourceNode` 播放 48 kHz 雙聲道 s16le，環形緩衝區超過 200ms 就丟掉舊資料維持低延遲。

### KeyMap.swift
Mac 虛擬 keyCode（與鍵盤配置、輸入法無關）→ Android keycode；修飾鍵 → meta state；Mac 輸入法模式下 `NSTextInputClient` 的指令（換行、刪除、方向鍵等）→ keycode。Esc 對應返回。

### MirrorView.swift
顯示畫面並轉送輸入的 `NSView`。
- 滑鼠左鍵 = 觸控；右鍵 = 返回（螢幕關閉時點亮）；中鍵 = 主畫面。
- 觸控板捲動：模擬單指拖曳（移動超過門檻才放下手指，忽略慣性階段，由 Android 自己算慣性）；一般滑鼠滾輪送捲動事件。
- 觸控板雙指縮放：以指標位置為中心、斜向擺放兩個虛擬手指。
- 鍵盤：實體按鍵模式不經過輸入法（`inputContext` 回傳 nil），依按鍵位置送 keycode；Mac 輸入法模式實作 `NSTextInputClient`，ASCII 用 INJECT_TEXT，中文等非 ASCII 用設定剪貼簿並貼上，組字中的文字顯示在畫面下方。
- ⌘V 貼上 Mac 剪貼簿、⌘C／⌘X 取得手機剪貼簿、⌘A 全選、⌘Z 復原、⌘←／→ 行首行尾、⌘⌫ 主畫面。
- 拖放檔案交給 `DropHandler`。

### MirrorModel.swift
一個鏡像視窗的狀態與工作階段管理。
- 啟動／重啟 session；重啟時先拔掉舊 session 的回呼（避免晚到的「已停止」被當成新連線中斷），並延遲 0.6 秒等舊 server 釋放硬體編碼器。
- 自動維持連線：連線中斷且裝置回來就重連。
- 虛擬顯示器大小：像素 = 視窗點數 × Mac 螢幕的 backing scale（非 Retina 就是 1:1），密度 160 × scale，讓 1 個 Mac 點約等於 1 個 Android dp；長寬取 8 的倍數（無條件捨去，不超過視窗）；受「最大解析度」限制。放開視窗邊框時依新大小重建虛擬顯示器（`resizeVirtualDisplay`）。
- 定時工作：Mac 剪貼簿 → 手機（0.7 秒）；主鏡像與桌面模式每 3 秒更新 App 列；主鏡像視窗在前景時偵測鎖定畫面。
- 操作：按鍵、黑屏切換、Mac 端靜音、啟動 App、截圖存到桌面、套用畫質（重啟）、拖放處理、Touch ID 解鎖。

### MirrorContentView.swift
鏡像視窗內容：左側 `AppRail`（主鏡像與桌面模式；已開啟的 App 左邊有點，最近使用的沒有；可把圖示拖出 App 列放開，就在放開位置以獨立視窗開啟，拖曳時由 `DragGhost` 顯示跟著游標的圖示）、上方工具列（電源、音量、旋轉、返回、主畫面、最近使用、通知欄、截圖、黑屏、靜音、鍵盤模式、畫質設定；桌面模式另有小型啟動台）、解鎖橫幅、組字文字、提示訊息（桌面模式還沒開 App 時提示從 App 列或啟動台開啟）。另含 `AppIconView`、`VideoSettingsPopover`、`LockPasswordSheet`、`MiniLauncher`、`DragGhost`。

### MirrorWindowController.swift
鏡像視窗。主螢幕鏡像依畫面比例調整與縮放（保留 App 列與工具列空間）；虛擬顯示器視窗可自由調整，放開邊框時請 `MirrorModel` 重建顯示器。可指定開啟位置，否則錯開排列；App 名稱載入後更新標題；關閉時停止工作階段。

### DropHandler.swift
拖進來的檔案：`.apk` 安裝；png/jpeg/jpg/heic/heif/mov/mp4 存到 `/sdcard/DCIM/Camera`；資料夾與其他檔案存到 `/sdcard/Download`。

### LockScreenHelper.swift
以 `dumpsys window`／`dumpsys activity activities` 的 keyguard 欄位判斷是否在鎖定畫面；解鎖密碼存在鑰匙圈（鍵 `lock.<裝置鍵>`）；`unlock` 先以 Touch ID（或 Mac 密碼）驗證，再喚醒、上滑、輸入密碼、Enter。

## Sources/PhoneCentre/Files

### RemoteFiles.swift
`RemoteFile` 與 `RemoteFS`：用 `stat -L -c '%F|%s|%Y|%n'` 列目錄、mkdir、mv、rm（附媒體掃描）、下載到快取（`files` 目錄，大小相同就不重抓）。`remoteFileItemProvider` 讓檔案可拖到 Finder（系統要資料時才從手機下載）。`stableHash` 是跨程序穩定的短雜湊。

### FileBrowserView.swift
Finder 風格檔案管理：位置側邊欄、上一頁／下一頁／上一層、路徑列、可排序表格（資料夾排前面）、雙擊開啟、快速查看（`QuickLookPresenter`）、重新命名、刪除、新增資料夾、上傳、下載、拖入上傳、拖出到 Finder、顯示隱藏檔。

## Sources/PhoneCentre/Photos

### CameraRollView.swift
Apple「照片」風格相機膠卷：相簿選擇（DCIM 與 Pictures 下的資料夾）、縮放滑桿、多選（⌘／⇧ 點選）、匯出、刪除、拖入匯入、拖出到 Finder、`MediaViewer` 檢視原圖或播放影片（左右鍵切換）。
`ThumbnailLoader`：格子出現才排隊、消失就取消，80ms 內的請求合併成一批交給手機端 `thumbs` 產生縮圖，結果存到 `thumbs` 快取（鍵含路徑、大小、修改時間與縮圖版本）。

## Sources/PhoneCentre/Launchpad

### LaunchpadView.swift
類似 Mac 新版啟動台：上方「開啟方式」下拉選單（獨立視窗／主螢幕）、全部／使用者／系統篩選、搜尋、App 圖示格（已開啟的下方有點）；右鍵選單可選開啟位置、App 資訊、強制停止、拷貝套件名稱、解除安裝。

## Sources/PhoneCentre/MenuBar

### MenuBarController.swift
選單列圖示，點開是 popover（大小跟著 SwiftUI 內容）：每台已連線裝置一區（名稱、型號、鏡像按鈕），下面一排 App 圖示（已開啟的下方有點、最近使用的沒有），點了依啟動台設定開啟；底部有開啟手機中心、設定、結束。

## Sources/PhoneCentre/Remote

### SecureChannel.swift
PhoneCentre 之間的加密通道：Network.framework 的 TLS（PSK，`TLS_PSK_WITH_AES_128_GCM_SHA256`），PSK 由密碼經 PBKDF2-SHA256（20 萬次）推導，雙方密碼相同才能完成握手。`pipe` 雙向轉送兩條連線。

### RemoteManager.swift
- `ShareServer`：開啟分享時在指定 port 監聽（並以 Bonjour 公告），通過 PSK 握手的連線轉送到本機 adb server（127.0.0.1:5037）；同一來源連續失敗 5 次起暫時封鎖。
- `RemoteManager`：每個遠端主機在本機 127.0.0.1 開一個隨機 port，進來的連線以 TLS 轉送到遠端；每 5 秒用 `host:version` 確認通道可用。對本機程式來說這就是另一個 adb server（`AdbEndpoint` 帶 remoteID），鏡像、檔案、App 等功能都可直接使用。

## Sources/PhoneCentre/Settings

### SettingsView.swift
設定視窗分頁：一般（選單列、Dock 模式、啟動台開啟方式）、連線（自動維持連線、記住的無線裝置、adb 路徑與下載）、鏡像（預設畫質、鍵盤模式、剪貼簿同步、音訊與手機靜音、黑屏、Touch ID 解鎖提示）、分享（開關、port、密碼、狀態）、儲存（設定檔資料夾／iCloud Drive、密碼是否同步、快取用量與上限、清除時機、清除快取、清除 Dock 副本）。

## Sources/PhoneCentre/Support

### Shell.swift
非同步執行外部程式（邊跑邊讀 stdout/stderr，避免 pipe 塞滿），以及 shell 單引號跳脫。

### Keychain.swift
generic password 的讀寫（service `com.iambjlu.PhoneCentre`）。

### CacheManager.swift
快取放在 `~/Library/Caches/PhoneCentre/<裝置鍵>/{icons,thumbs,files}`，裝置鍵優先用 ro.serialno（換 port 或改用 USB 都不變）。
- 清除時機：裝置斷線立即清除該裝置的快取／幾天沒連線才清除（記錄在 `last-seen.json`）／只依容量。
- 容量上限：依最後存取時間（LRU）刪到上限的 90%；每分鐘檢查一次。

## 已知限制

- Samsung DeX 需要實體外接螢幕（或三星自己的無線 DeX），adb 建立的虛擬顯示器無法觸發；「桌面模式」改用 Android 的虛擬顯示器＋系統裝飾。若手機桌面程式不支援第二螢幕（例如 S10 / One UI 4），桌面上沒有背景與桌面圖示，改由視窗左側 App 列或工具列的小型啟動台開啟 App。
- 調整獨立 App 視窗大小會重建虛擬顯示器，過程中 App 會短暫回到手機主螢幕。
- 音訊轉送需要 Android 11 以上；「手機同時發聲」需要 Android 13 以上。
- 由 PhoneCentre 啟動的 adb server 連線區域網路手機時，macOS 會詢問 PhoneCentre 的「區域網路」權限；用 ad-hoc 簽章時每次重新編譯都要重新允許。
