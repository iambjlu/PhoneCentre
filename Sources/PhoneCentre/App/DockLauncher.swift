import AppKit
import CryptoKit
import Foundation

/// 子程序模式：一個 PhoneCentre 子程序只開一個鏡像／App 視窗，Dock 上有自己的圖示與名稱
enum ChildMode {
    struct Args {
        var serial: String
        var endpoint: AdbEndpoint
        var package: String?
        var desktop: Bool
        var iconPath: String?
        var label: String?
        var topLeft: NSPoint?
        var roSerial: String?
    }

    /// 副本旁邊的啟動參數檔：從 Dock 釘選的圖示直接點開時沒有命令列參數，改讀這個檔
    struct Params: Codable {
        var serial: String
        var roSerial: String?
        var host: String
        var port: Int
        var remote: String?
        var package: String?
        var label: String?
        var desktop: Bool
        var icon: String?
    }

    static var paramsFile: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier?.hasPrefix("com.iambjlu.PhoneCentre.w") == true else { return nil }
        return bundle.deletingLastPathComponent().appendingPathComponent("params.json")
    }

    static let args: Args? = {
        let a = CommandLine.arguments
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if a.contains("--child"), let serial = value("--serial") {
            var ep = AdbEndpoint(host: value("--host") ?? "127.0.0.1", port: Int(value("--port") ?? "") ?? 5037)
            ep.remoteID = value("--remote").flatMap(UUID.init(uuidString:))
            return Args(serial: serial, endpoint: ep, package: value("--package"),
                        desktop: a.contains("--desktop"), iconPath: value("--icon"), label: value("--label"),
                        topLeft: value("--at").flatMap { s -> NSPoint? in
                            let p = s.split(separator: ",").compactMap { Double($0) }
                            return p.count == 2 ? NSPoint(x: p[0], y: p[1]) : nil
                        }, roSerial: loadParams()?.roSerial)
        }
        guard let p = loadParams() else { return nil }
        var ep = AdbEndpoint(host: p.host, port: p.port)
        ep.remoteID = p.remote.flatMap(UUID.init(uuidString:))
        return Args(serial: p.serial, endpoint: ep, package: p.package, desktop: p.desktop,
                    iconPath: p.icon, label: p.label, topLeft: nil, roSerial: p.roSerial)
    }()

    private static func loadParams() -> Params? {
        guard let f = paramsFile, let raw = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(Params.self, from: raw)
    }

    static var isChild: Bool { args != nil }

    @MainActor
    static func bootstrap() {
        guard let a = args else { return }
        if let p = a.iconPath, let img = NSImage(contentsOfFile: p) {
            NSApp.applicationIconImage = rounded(img)
        }
        Task {
            var d = Device(serial: a.serial, state: "device", endpoint: a.endpoint)
            if let ro = a.roSerial, let found = await resolve(serial: a.serial, roSerial: ro, endpoint: a.endpoint) { d.serial = found }
            d.info = await DeviceInfo.fetch(d.client)
            WindowManager.shared.show(d, package: a.package, desktop: a.desktop, label: a.label, at: a.topLeft)
            // 子程序也載入 App 清單（名稱、圖示），給左側 App 列與拖出的視窗標題使用
            await DeviceManager.shared.catalog(for: d).reload()
        }
    }

    /// 原本的序號不在線上（例如無線偵錯 port 變了）時，用 ro.serialno 找出同一支手機
    private static func resolve(serial: String, roSerial: String, endpoint: AdbEndpoint) async -> String? {
        guard let text = try? await Task.detached(operation: { try AdbSocket.hostQuery(endpoint, "host:devices-l") }).value else { return nil }
        let online = Device.parse(text, endpoint: endpoint).filter(\.isOnline)
        if online.contains(where: { $0.serial == serial }) { return nil }
        for d in online where await d.client.getprop("ro.serialno") == roSerial { return d.serial }
        return nil
    }

    /// Android 圖示補上圓角底板，看起來比較像 Mac 圖示
    static func rounded(_ img: NSImage) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { r in
            let inset = r.insetBy(dx: 50, dy: 50)
            img.draw(in: inset)
            return true
        }
    }
}

/// 建立／啟動子程序用的 .app 副本（APFS clone，幾乎不佔空間），讓每個視窗在 Dock 上獨立
@MainActor
enum DockLauncher {
    static var dir: URL {
        let d = AdbLocator.supportDir.appendingPathComponent("Launchers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func launch(device: Device, package: String?, desktop: Bool, title: String, icon: NSImage?, at point: NSPoint? = nil) {
        let keySource = "\(CacheManager.key(for: device))|\(package ?? (desktop ? "@desktop" : "@main"))"
        let hash = SHA256.hash(data: Data(keySource.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let bundleID = "com.iambjlu.PhoneCentre.w\(hash)"

        // 已在執行就直接切過去
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
            return
        }

        let bad = CharacterSet(charactersIn: "/:\\\"*?<>|").union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { bad.contains($0) ? "-" : $0 }))
        let safeTitle = String(cleaned.prefix(40))
        // 每個視窗一個資料夾（用雜湊區分），.app 本身用乾淨的名稱，Dock 釘選後名稱才好看
        let folder = dir.appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("\(safeTitle.isEmpty ? "PhoneCentre" : safeTitle).app")
        Task {
            do {
                try await prepare(app, bundleID: bundleID, title: title)
            } catch {
                DeviceManager.shared.log("無法建立 Dock 獨立視窗：\(error.localizedDescription)，改在主程式開啟")
                WindowManager.shared.show(device, package: package, desktop: desktop)
                return
            }
            await open(app, bundleID: bundleID, title: title, device: device, package: package, desktop: desktop, icon: icon, hash: hash, at: point, retry: true)
        }
    }

    /// 啟動副本；失敗時（例如副本損壞、簽章或隔離屬性問題）重建一次再試，真的不行才改在主程式開
    private static func open(_ app: URL, bundleID: String, title: String, device: Device, package: String?, desktop: Bool,
                             icon: NSImage?, hash: String, at point: NSPoint?, retry: Bool) async {
        do {
            var args = ["--child", "--serial", device.serial,
                        "--host", device.endpoint.host, "--port", String(device.endpoint.port)]
            if let r = device.endpoint.remoteID { args += ["--remote", r.uuidString] }
            if let package { args += ["--package", package, "--label", title] }
            if desktop { args.append("--desktop") }
            if let point { args += ["--at", "\(Int(point.x)),\(Int(point.y))"] }
            if let icon, let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let iconFile = dir.appendingPathComponent("\(hash).png")
                try? png.write(to: iconFile)
                args += ["--icon", iconFile.path]
                NSWorkspace.shared.setIcon(ChildMode.rounded(icon), forFile: app.path, options: [])
            }
            // 啟動參數另存在副本旁邊：從 Dock 釘選的圖示再次點開時，用這個檔當作參數（不會變成另一個完整的 PhoneCentre）
            let params = ChildMode.Params(serial: device.serial,
                                          roSerial: device.info?.serialNo,
                                          host: device.endpoint.host, port: device.endpoint.port,
                                          remote: device.endpoint.remoteID?.uuidString,
                                          package: package, label: package == nil ? nil : title, desktop: desktop,
                                          icon: icon == nil ? nil : dir.appendingPathComponent("\(hash).png").path)
            if let raw = try? JSONEncoder().encode(params) {
                try? raw.write(to: app.deletingLastPathComponent().appendingPathComponent("params.json"), options: .atomic)
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = args
            cfg.createsNewApplicationInstance = false
            cfg.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        } catch {
            if retry {
                DeviceManager.shared.log("獨立視窗啟動失敗（\(error.localizedDescription)），重建後重試")
                try? FileManager.default.removeItem(at: app)
                do { try await prepare(app, bundleID: bundleID, title: title) } catch {}
                try? await Task.sleep(nanoseconds: 500_000_000)
                await open(app, bundleID: bundleID, title: title, device: device, package: package, desktop: desktop,
                           icon: icon, hash: hash, at: point, retry: false)
            } else {
                DeviceManager.shared.log("啟動獨立視窗失敗：\(error.localizedDescription)，改在主程式開啟")
                WindowManager.shared.show(device, package: package, desktop: desktop)
            }
        }
    }

    /// 主程式更新後，副本也要重新建立
    private static func prepare(_ app: URL, bundleID: String, title: String) async throws {
        let fm = FileManager.default
        let main = Bundle.main.bundleURL
        guard main.pathExtension == "app" else { throw AdbError.failed("不是以 .app 執行") }
        let mainExe = main.appendingPathComponent("Contents/MacOS/PhoneCentre")
        let cloneExe = app.appendingPathComponent("Contents/MacOS/PhoneCentre")
        let mainDate = (try? fm.attributesOfItem(atPath: mainExe.path)[.modificationDate] as? Date) ?? .distantPast
        let cloneDate = (try? fm.attributesOfItem(atPath: cloneExe.path)[.modificationDate] as? Date) ?? .distantPast
        if fm.fileExists(atPath: app.path), cloneDate >= mainDate { return }

        try? fm.removeItem(at: app)
        let cp = try await Shell.run("/bin/cp", ["-c", "-R", main.path, app.path])
        if cp.status != 0 {
            let cp2 = try await Shell.run("/bin/cp", ["-R", main.path, app.path])
            if cp2.status != 0 { throw AdbError.failed(cp2.stderr) }
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSMutableDictionary(contentsOf: plist) else { throw AdbError.failed("Info.plist") }
        dict["CFBundleIdentifier"] = bundleID
        dict["CFBundleName"] = String(title.prefix(15))
        dict["CFBundleDisplayName"] = title
        dict.write(to: plist, atomically: true)
        // 從別台電腦／AirDrop 來的主程式帶有隔離屬性，複製後會被 Gatekeeper 擋下（「無法打開」）
        _ = try await Shell.run("/usr/bin/xattr", ["-cr", app.path])
        _ = try await Shell.run("/usr/bin/touch", [cloneExe.path])
        let sign = try await Shell.run("/usr/bin/codesign", ["--force", "--deep", "-s", "-", app.path])
        if sign.status != 0 { throw AdbError.failed("簽章失敗：\(sign.stderr)") }
    }

    /// 清除所有副本
    static func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}
