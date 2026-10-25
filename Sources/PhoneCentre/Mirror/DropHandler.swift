import Foundation

/// 拖進手機視窗的檔案：apk 安裝；照片影片存到 DCIM/Camera；其他存到 Download
enum DropHandler {
    static let mediaExts: Set<String> = ["png", "jpeg", "jpg", "heic", "heif", "mov", "mp4"]

    static func destination(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "apk" { return nil }
        if mediaExts.contains(ext) { return "/sdcard/DCIM/Camera/" + url.lastPathComponent }
        return "/sdcard/Download/" + url.lastPathComponent
    }

    /// 依序處理，透過 progress 回報狀態文字
    static func handle(_ urls: [URL], device: Device, progress: @escaping @MainActor (String) -> Void) async {
        let c = device.client
        var failures: [String] = []
        for (i, url) in urls.enumerated() {
            let prefix = urls.count > 1 ? "(\(i + 1)/\(urls.count)) " : ""
            do {
                if url.hasDirectoryPath {
                    await progress(prefix + "正在傳送資料夾 \(url.lastPathComponent)…")
                    try await c.push(url, to: "/sdcard/Download/")
                } else if let dest = destination(for: url) {
                    await progress(prefix + "正在傳送 \(url.lastPathComponent)…")
                    try await c.push(url, to: dest)
                } else {
                    await progress(prefix + "正在安裝 \(url.lastPathComponent)…")
                    try await c.install(url)
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        await progress(failures.isEmpty ? "完成" : "失敗：\n" + failures.joined(separator: "\n"))
    }
}
