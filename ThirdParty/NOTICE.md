# 第三方元件聲明

## scrcpy-server

PhoneCentre 內含未經修改的 scrcpy 官方 release 檔案 `scrcpy-server`（v3.3.4），
在裝置端以 `app_process` 執行，負責擷取畫面與注入輸入事件。
Mac 端的用戶端（解碼、顯示、操控協定）由 PhoneCentre 以 Swift 獨立實作，未使用 scrcpy 用戶端程式碼。

- 專案：https://github.com/Genymobile/scrcpy
- Copyright (C) 2018 Genymobile
- Copyright (C) 2018-2025 Romain Vimont
- 授權：Apache License 2.0，全文見 `licenses/scrcpy-LICENSE.txt`

## Android SDK Platform-Tools（adb）

PhoneCentre **不內含** adb。若系統找不到 adb，PhoneCentre 會在用戶同意後，
從 Google 官方網址（https://dl.google.com/android/repository/platform-tools-latest-darwin.zip）
下載 Android SDK Platform-Tools 到
`~/Library/Application Support/PhoneCentre/platform-tools`。
Platform-Tools 受 Android Software Development Kit License Agreement 約束：
https://developer.android.com/studio/terms
