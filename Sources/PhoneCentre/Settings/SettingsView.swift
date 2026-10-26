import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "gearshape") }
            ConnectionSettings().tabItem { Label("連線", systemImage: "cable.connector") }
            MirrorSettings().tabItem { Label("鏡像", systemImage: "rectangle.on.rectangle") }
            ShareSettings().tabItem { Label("遠端 (Beta)", systemImage: "network") }
            StorageSettings().tabItem { Label("儲存", systemImage: "internaldrive") }
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("選單列") {
                Toggle("在選單列顯示圖示", isOn: $s.data.showMenuBarIcon)
                    .onChange(of: s.showMenuBarIcon) { _, v in (NSApp.delegate as? AppDelegate)?.setMenuBarVisible(v) }
            }
            Section("Dock") {
                Picker("手機鏡像視窗", selection: $s.data.mirrorDockMode) {
                    ForEach(DockMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("獨立視窗的 App", selection: $s.data.appWindowDockMode) {
                    ForEach(DockMode.allCases) { Text($0.title).tag($0) }
                }
                Text("「每個視窗各自一個」會以獨立程序開啟視窗，Dock 上顯示手機名稱或 App 圖示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("啟動台") {
                Picker("點 App 時", selection: $s.data.launchTarget) {
                    ForEach(AppLaunchTarget.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var dm = DeviceManager.shared
    @State private var installMsg = ""

    var body: some View {
        Form {
            Section("自動維持連線") {
                Toggle("adb server 被關掉時自動重新啟動，並重連無線裝置", isOn: $s.data.keepAlive)
                Toggle("記住連線過的無線裝置", isOn: $s.data.rememberWireless)
            }
            Section("記住的無線裝置") {
                if s.savedEndpoints.isEmpty { Text("沒有").foregroundStyle(.secondary) }
                ForEach(s.savedEndpoints) { ep in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ep.name ?? ep.address)
                            Text(ep.address).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("忘記") { dm.forget(ep) }
                    }
                }
            }
            Section("adb") {
                LabeledContent("目前使用", value: AdbLocator.find() ?? "找不到")
                TextField("自訂 adb 路徑（留白自動尋找）", text: $s.customAdbPath)
                HStack {
                    Button("下載／更新 Google Platform-Tools") {
                        Task {
                            do { _ = try await AdbLocator.install { m in Task { @MainActor in installMsg = m } } }
                            catch { installMsg = error.localizedDescription }
                        }
                    }
                    Text(installMsg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MirrorSettings: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("預設畫質（每台手機可在鏡像視窗個別調整）") {
                Picker("FPS", selection: $s.data.video.maxFps) {
                    ForEach([15, 24, 30, 45, 60, 90, 120], id: \.self) { Text("\($0)").tag($0) }
                }
                HStack {
                    Text("Bitrate")
                    Slider(value: $s.data.video.bitRateMbps, in: 0.5...40, step: 0.5)
                    Text(String(format: "%.1f Mbps", s.video.bitRateMbps)).monospacedDigit().frame(width: 72)
                }
                Picker("最大解析度", selection: $s.data.video.maxSize) {
                    Text("不限制").tag(0)
                    ForEach([2560, 1920, 1600, 1280, 1024, 800, 640], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("輸入") {
                Picker("鍵盤模式", selection: $s.data.keyboardMode) {
                    ForEach(KeyboardMode.allCases) { Text($0.title).tag($0) }
                }
                Text("實體按鍵：依按鍵位置送出，不受 Mac 輸入法影響（注音模式下打英文也正確）。\nMac 輸入法：用 Mac 的注音等輸入法組字後送出文字。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("同步剪貼簿（Mac ↔ 手機）", isOn: $s.data.clipboardSync)
            }
            Section("音訊") {
                Toggle("把手機聲音傳到 Mac（Android 11 以上）", isOn: $s.data.audioEnabled)
                Toggle("傳到 Mac 時手機不發出聲音", isOn: $s.data.muteDeviceWhenForwarding)
                    .disabled(!s.audioEnabled)
                Text("關閉這個選項時，手機和 Mac 同時發聲（需要 Android 13 以上；較舊的手機一律靜音）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("螢幕") {
                Toggle("鏡像時讓手機黑屏", isOn: $s.data.turnScreenOffWhileMirroring)
                Toggle("偵測到鎖定畫面時，提供 Touch ID 填入解鎖密碼", isOn: $s.data.offerTouchIDUnlock)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShareSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var server = ShareServer.shared
    @State private var password = AppSettings.shared.sharePassword
    @State private var port = String(AppSettings.shared.sharePort)

    var body: some View {
        Form {
            Section {
                Toggle("啟用遠端 PhoneCentre 功能 (Beta)", isOn: $s.data.remoteEnabled)
                Text("包含「連到其他 PhoneCentre」與「讓其他 PhoneCentre 連入」。關閉後不會連任何遠端主機、不開任何對外的 port，也不在區域網路上公告；側邊欄與「加入裝置」裡的遠端項目都會隱藏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("讓其他 PhoneCentre 連入") {
                Toggle("開啟分享", isOn: $s.data.shareEnabled)
                TextField("Port", text: $port)
                SecureField("密碼（至少 6 個字元）", text: $password)
                HStack {
                    Button("套用") {
                        s.sharePort = Int(port) ?? 47_500
                        s.sharePassword = password
                        server.apply()
                    }
                    Spacer()
                    Text(server.status).foregroundStyle(.secondary)
                    if server.activeConnections > 0 { Text("· \(server.activeConnections) 條連線").foregroundStyle(.secondary) }
                }
            }
            .disabled(!s.remoteEnabled)
            Section {
                Text("連線使用 TLS 加密（PSK，金鑰由密碼經 PBKDF2 推導），密碼錯誤無法完成握手；同一來源連續失敗會暫時封鎖。對方可以操作這台 Mac 連接的所有手機，請只把密碼給信任的人。若要從外網連入，需要在路由器設定 port 轉送。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.shareEnabled) { _, _ in server.apply() }
        .onChange(of: s.remoteEnabled) { _, _ in server.apply(); RemoteManager.shared.apply() }
    }
}

private struct StorageSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var cache = CacheManager.shared

    var body: some View {
        Form {
            Section("設定檔位置") {
                LabeledContent("目前", value: s.settingsFolder?.path ?? "這台 Mac（本機）")
                HStack {
                    Button("選擇資料夾（例如 iCloud Drive）…") { chooseFolder() }
                    if s.settingsFolder != nil { Button("改回本機") { s.setSettingsFolder(nil) } }
                }
                Toggle("密碼也存到這個資料夾", isOn: $s.data.syncSecrets)
                    .disabled(s.settingsFolder == nil)
                Text(s.syncSecrets
                     ? "⚠️ 手機解鎖密碼、分享密碼會以明碼寫在 settings.json，並同步到所有登入同一個 Apple ID 的電腦。"
                     : "密碼只存在這台 Mac 的鑰匙圈。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("把 PhoneCentre.app 帶到另一台 Mac，選同一個 iCloud Drive 資料夾就能沿用設定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("簡訊、通知、通話記錄（透過 adb 讀取，不需在手機安裝程式）") {
                Toggle("定時收集並保存在這台 Mac", isOn: $s.data.phoneDataEnabled)
                PhoneDataRetentionPicker(title: "簡訊保存", days: $s.data.smsRetentionDays)
                PhoneDataRetentionPicker(title: "通知保存", days: $s.data.notificationRetentionDays)
                PhoneDataRetentionPicker(title: "通話記錄保存", days: $s.data.callRetentionDays)
                Text("通知只能在手機連線期間記錄；手機上還在的通知不受保存天數影響，清掉之後才開始計算。超過天數的資料會自動刪除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: s.data.smsRetentionDays) { _, _ in PhoneDataStore.shared.prune() }
            .onChange(of: s.data.callRetentionDays) { _, _ in PhoneDataStore.shared.prune() }
            .onChange(of: s.data.notificationRetentionDays) { _, _ in PhoneDataStore.shared.prune() }
            Section("快取（App 圖示、相片縮圖、預覽下載）") {
                LabeledContent("目前使用", value: cache.totalBytes.fileSizeString)
                Stepper("上限：\(s.cacheLimitMB) MB", value: $s.data.cacheLimitMB, in: 20...10_000, step: 50)
                Picker("清除時機", selection: $s.data.cacheClearPolicy) {
                    ForEach(CacheClearPolicy.allCases) { Text($0.title).tag($0) }
                }
                if s.cacheClearPolicy == .afterDays {
                    Stepper("\(s.cacheClearDays) 天沒連線就清除", value: $s.data.cacheClearDays, in: 1...365)
                }
                HStack {
                    Button("立即套用") { cache.enforce() }
                    Button("清除全部快取", role: .destructive) { cache.clearAll() }
                    Button("清除 Dock 獨立視窗副本") { DockLauncher.cleanup() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cache.recalc() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "使用這個資料夾"
        panel.message = "選擇存放 PhoneCentre 設定的資料夾（放在 iCloud Drive 裡就能在多台 Mac 同步）"
        panel.directoryURL = AppSettings.iCloudDriveURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        s.setSettingsFolder(url)
    }
}
