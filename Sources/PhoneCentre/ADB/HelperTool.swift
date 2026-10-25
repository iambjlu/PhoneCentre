import Foundation

/// 在手機端執行 phonecentre-helper.jar（App 清單、圖示、相片縮圖）
actor HelperTool {
    static let shared = HelperTool()
    static let remotePath = "/data/local/tmp/phonecentre-helper.jar"
    private var pushed: Set<String> = []

    private func ensure(_ device: Device) async throws {
        if pushed.contains(device.id) { return }
        guard let jar = Bundle.main.url(forResource: "phonecentre-helper", withExtension: "jar") else {
            throw AdbError.failed("App 內缺少 phonecentre-helper.jar")
        }
        let localSize = (try? FileManager.default.attributesOfItem(atPath: jar.path)[.size] as? Int) ?? -1
        let remoteSize = Int((try? await device.client.shell("stat -c %s \(Self.remotePath) 2>/dev/null"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -2
        if localSize != remoteSize { try await device.client.push(jar, to: Self.remotePath) }
        pushed.insert(device.id)
    }

    func run(_ device: Device, _ args: [String], timeout: TimeInterval = 60) async throws -> String {
        try await ensure(device)
        let argStr = args.map(Shell.quote).joined(separator: " ")
        return try await device.client.shell(
            "CLASSPATH=\(Self.remotePath) app_process / com.phonecentre.helper.Main \(argStr) 2>/dev/null",
            timeout: timeout)
    }
}
