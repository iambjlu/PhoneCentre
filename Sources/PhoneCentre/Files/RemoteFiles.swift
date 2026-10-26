import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// 手機上的一個檔案或資料夾
struct RemoteFile: Identifiable, Hashable {
    var path: String
    var name: String
    var isDir: Bool
    var size: Int64
    var modified: Date
    var id: String { path }

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var utType: UTType { isDir ? .folder : (UTType(filenameExtension: ext) ?? .data) }
    var isMedia: Bool { utType.conforms(to: .image) || utType.conforms(to: .movie) }
    var isVideo: Bool { utType.conforms(to: .movie) }
    var kind: String { isDir ? "資料夾" : (utType.localizedDescription ?? ext.uppercased()) }
    var icon: NSImage { NSWorkspace.shared.icon(for: utType) }
}

/// 手機檔案操作（透過 adb shell / push / pull）
struct RemoteFS {
    let device: Device
    var client: AdbClient { device.client }

    func list(_ dir: String, showHidden: Bool) async throws -> [RemoteFile] {
        let globs = showHidden ? "* .[!.]* ..?*" : "*"
        // stat -L：跟隨連結（/sdcard 等是 symlink）；%F 類型、%s 大小、%Y 修改時間、%n 名稱
        let out = try await client.shell(
            "cd \(Shell.quote(dir)) 2>&1 || exit 1; stat -L -c '%F|%s|%Y|%n' -- \(globs) 2>/dev/null", timeout: 30)
        if out.contains("can't cd") || out.contains("No such file") || out.contains("Permission denied") {
            throw AdbError.failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, p[3] != "*", p[3] != ".[!.]*", p[3] != "..?*" else { return nil }
            return RemoteFile(path: base + p[3], name: p[3], isDir: p[0].contains("directory"),
                              size: Int64(p[1]) ?? 0, modified: Date(timeIntervalSince1970: TimeInterval(p[2]) ?? 0))
        }
    }

    /// 資料夾底下所有檔案（含子資料夾，略過隱藏檔與隱藏資料夾，例如 .thumbnails）
    func listRecursive(_ dir: String) async throws -> [RemoteFile] {
        let out = try await client.shell(
            "cd \(Shell.quote(dir)) 2>&1 || exit 1; find . -type f ! -path '*/.*' -exec stat -L -c '%F|%s|%Y|%n' {} + 2>/dev/null", timeout: 120)
        if out.contains("can't cd") || out.contains("No such file") { throw AdbError.failed(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, p[3].hasPrefix("./") else { return nil }
            let rel = String(p[3].dropFirst(2))
            return RemoteFile(path: base + "/" + rel, name: (rel as NSString).lastPathComponent, isDir: false,
                              size: Int64(p[1]) ?? 0, modified: Date(timeIntervalSince1970: TimeInterval(p[2]) ?? 0))
        }
    }

    func mkdir(_ path: String) async throws {
        try check(await client.shell("mkdir -p \(Shell.quote(path)) 2>&1"))
    }

    func rename(_ path: String, to newPath: String) async throws {
        try check(await client.shell("mv -n \(Shell.quote(path)) \(Shell.quote(newPath)) 2>&1"))
    }

    func delete(_ paths: [String]) async throws {
        try check(await client.shell("rm -rf " + paths.map(Shell.quote).joined(separator: " ") + " 2>&1"))
        // 通知媒體庫
        for p in paths {
            _ = try? await client.shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Shell.quote("file://" + p)) >/dev/null 2>&1")
        }
    }

    /// 下載到暫存（預覽用），已下載過且大小相同就不重抓
    @MainActor
    func download(toCache f: RemoteFile) async throws -> URL {
        let dir = CacheManager.shared.dir(device, "files")
        let local = dir.appendingPathComponent(stableHash(f.path)).appendingPathComponent(f.name)
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? -1
        if size == f.size { return local }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await client.pull(f.path, to: local)
        CacheManager.shared.recalc()
        return local
    }

    private func check(_ out: String) throws {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { throw AdbError.failed(t) }
    }
}

/// 跨程序穩定的短雜湊（String.hashValue 每次啟動都不同）
func stableHash(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

extension Int64 {
    var fileSizeString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// 拖出到 Finder：系統要資料時才從手機下載
func remoteFileItemProvider(_ f: RemoteFile, device: Device) -> NSItemProvider {
    let provider = NSItemProvider()
    let type = f.isDir ? UTType.folder : f.utType
    // 有副檔名的檔案不要設 suggestedName：系統會再依型別補一次副檔名（變成 .jpg.jpeg），
    // 不設的話就直接用下面交出去的檔案名稱
    if f.isDir || (f.name as NSString).pathExtension.isEmpty { provider.suggestedName = f.name }
    provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneCentre-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent(f.name)
        Task {
            do {
                try await device.client.pull(f.path, to: dest)
                done(dest, false, nil)
            } catch {
                done(nil, false, error)
            }
        }
        return nil
    }
    return provider
}
