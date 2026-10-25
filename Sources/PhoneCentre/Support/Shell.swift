import Foundation

struct ShellResult {
    var status: Int32
    var stdout: Data
    var stderr: String
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// 非同步執行外部程式
enum Shell {
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inPipe = stdin.map { _ in Pipe() }
            p.standardInput = inPipe ?? FileHandle.nullDevice

            // 輸出要邊跑邊讀，避免 pipe 塞滿卡死
            let lock = NSLock()
            var outData = Data(), errData = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); outData.append(d); lock.unlock()
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); errData.append(d); lock.unlock()
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let restOut = out.fileHandleForReading.readDataToEndOfFile()
                let restErr = err.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                outData.append(restOut); errData.append(restErr)
                let r = ShellResult(status: proc.terminationStatus, stdout: outData,
                                    stderr: String(decoding: errData, as: UTF8.self))
                lock.unlock()
                cont.resume(returning: r)
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            if let inPipe, let stdin {
                DispatchQueue.global().async {
                    inPipe.fileHandleForWriting.write(stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
            }
        }
    }

    /// 單引號跳脫，給 adb shell 使用
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
