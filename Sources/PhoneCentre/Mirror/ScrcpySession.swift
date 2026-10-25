import AppKit
import AVFoundation
import Foundation

/// 鏡像工作階段的參數
struct MirrorConfig {
    var video = VideoOptions()
    var audio = true
    var muteDevice = true
    var clipboardSync = true
    var screenOff = false
    /// 非 nil 時在新的虛擬顯示器上執行，格式 "WxH/dpi"
    var newDisplay: String?
    var systemDecorations = false
    /// 連線後要啟動的 App（套件名稱）
    var startApp: String?
}

/// 一個 scrcpy-server 連線：推送 server、建立 video / audio / control 三條 socket，解碼並轉送控制事件
final class ScrcpySession {
    static let serverVersion = "3.3.4"
    static let serverRemotePath = "/data/local/tmp/phonecentre-scrcpy-server.jar"

    enum State: Equatable { case idle, starting, running, failed(String), stopped }

    let device: Device
    let config: MirrorConfig
    let decoder = VideoDecoder()
    private(set) var deviceName = ""
    private(set) var frameSize: CGSize = .zero
    private(set) var state: State = .idle

    // 事件（一律在主執行緒呼叫）
    var onState: ((State) -> Void)?
    var onFrameSize: ((CGSize) -> Void)?
    var onSample: ((CMSampleBuffer, Bool) -> Void)?
    var onDeviceClipboard: ((String) -> Void)?

    private var shellSocket: AdbSocket?
    private var videoSocket: AdbSocket?
    private var audioSocket: AdbSocket?
    private var controlSocket: AdbSocket?
    private let controlQueue = DispatchQueue(label: "PhoneCentre.control")
    private var audioPlayer: AudioPlayer?
    private var stopped = false
    private var clipboardSeq: UInt64 = 1
    private var serverLog = ""

    init(device: Device, config: MirrorConfig) {
        self.device = device
        self.config = config
        decoder.onSizeChange = { [weak self] size in
            DispatchQueue.main.async {
                self?.frameSize = size
                self?.onFrameSize?(size)
            }
        }
        decoder.enqueue = { [weak self] sample, changed in self?.onSample?(sample, changed) }
    }

    private func setState(_ s: State) {
        DispatchQueue.main.async {
            self.state = s
            self.onState?(s)
        }
    }

    // MARK: 啟動

    func start() {
        setState(.starting)
        Thread.detachNewThread { [self] in
            do {
                try run()
            } catch {
                if !stopped {
                    let extra = serverLog.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("Exception") }.prefix(3).joined(separator: "\n")
                    setState(.failed(error.localizedDescription + (extra.isEmpty ? "" : "\n" + extra)))
                }
            }
        }
    }

    private func run() throws {
        try pushServerIfNeeded()

        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7fff_ffff))
        let prefix = "app_process / com.genymobile.scrcpy.Server \(Self.serverVersion) scid=\(scid) tunnel_forward=true"
        let cmd = "CLASSPATH=\(Self.serverRemotePath) " + Self.limitLength(prefix, serverArgs())

        // 用 shell:（有 pty）啟動；在部分三星 Android 12 上用 exec: 會讓 server 原生崩潰。
        // 關閉這條連線時 server 會收到 SIGHUP 一起結束。
        let shell = try AdbSocket.open(device.endpoint, serial: device.serial, service: "shell:" + cmd)
        shellSocket = shell
        Thread.detachNewThread { [weak self, shell] in
            while let d = try? shell.readSome() {
                let s = String(decoding: d, as: UTF8.self)
                self?.serverLog += s
                NSLog("[scrcpy-server] %@", s)
            }
        }

        // 依序連線 video → audio → control，第一條 socket 會先收到 1 byte dummy
        let socketName = "localabstract:scrcpy_\(scid)"
        var video: AdbSocket?
        for _ in 0..<100 {
            if stopped { throw AdbError.closed }
            if let s = try? AdbSocket.open(device.endpoint, serial: device.serial, service: socketName, timeout: 2) {
                s.setTimeout(2)
                if (try? s.readExact(1)) != nil { video = s; break }
                s.close()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let video else { throw AdbError.failed("無法連線到 scrcpy-server\n" + serverLog.suffix(400)) }
        video.setTimeout(0)
        videoSocket = video
        if config.audio {
            audioSocket = try AdbSocket.open(device.endpoint, serial: device.serial, service: socketName)
        }
        let control = try AdbSocket.open(device.endpoint, serial: device.serial, service: socketName)
        controlSocket = control

        // 裝置名稱（64 bytes）
        let nameData = try video.readExact(64)
        deviceName = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)

        // 影像 codec meta：codec id、寬、高
        let meta = try video.readExact(12)
        let codec = meta.be32(0)
        if codec == 0 || codec == 1 { throw AdbError.failed("裝置無法擷取畫面") }
        frameSize = CGSize(width: Int(meta.be32(4)), height: Int(meta.be32(8)))
        let fs = frameSize
        DispatchQueue.main.async { self.onFrameSize?(fs) }

        setState(.running)
        startControlReader(control)
        if let a = audioSocket { startAudio(a) }

        if config.screenOff { send(.setDisplayPower(false)) }
        if let app = config.startApp { send(.startApp(app)) }

        // 影像封包迴圈
        while !stopped {
            let header = try video.readExact(12)
            let ptsFlags = header.be64(0)
            let size = Int(header.be32(8))
            let packet = try video.readExact(size)
            if ptsFlags & (1 << 63) != 0 {
                decoder.handleConfig(packet)
            } else {
                decoder.handleFrame(packet, pts: ptsFlags & 0x3fff_ffff_ffff_ffff, keyFrame: ptsFlags & (1 << 62) != 0)
            }
        }
    }

    /// 只送跟 scrcpy-server 預設值不同的參數，依重要性排序（越後面越先被捨棄）
    private func serverArgs() -> [String] {
        let v = config.video
        var args: [String] = []
        if let nd = config.newDisplay {
            args.append("new_display=\(nd)")
            if !config.systemDecorations { args.append("vd_system_decorations=false") }
        }
        if config.audio {
            args.append("audio_codec=raw")
            if !config.muteDevice, device.info.map({ $0.sdk >= 33 }) ?? false {
                // Android 13+：擷取播放音訊，同時讓手機繼續發聲（預設 output 會讓手機靜音）
                args += ["audio_source=playback", "audio_dup=true"]
            }
        } else {
            args.append("audio=false")
        }
        if v.maxSize > 0 { args.append("max_size=\(v.maxSize)") }
        let bitRate = Int(v.bitRateMbps * 1_000_000)
        if bitRate != 8_000_000 { args.append("video_bit_rate=\(bitRate)") }
        if v.maxFps > 0 { args.append("max_fps=\(v.maxFps)") }
        if !config.clipboardSync { args.append("clipboard_autosync=false") }
        if config.newDisplay != nil { args.append("vd_destroy_content=false") }
        return args
    }

    /// 三星部分機型（例如 S10 / Android 12）的 libstagefright 在設定編碼器時會把程序 cmdline
    /// 讀進固定大小的緩衝區，app_process 的參數超過約 257 字元就會 stack corruption 崩潰，
    /// 所以把總長度壓在 240 以內，超過就從最後面開始捨棄參數。
    static func limitLength(_ prefix: String, _ args: [String], max: Int = 240) -> String {
        var args = args
        var line = ([prefix] + args).joined(separator: " ")
        while line.utf8.count > max, !args.isEmpty {
            args.removeLast()
            line = ([prefix] + args).joined(separator: " ")
        }
        return line
    }

    private func pushServerIfNeeded() throws {
        guard let local = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
            throw AdbError.failed("App 內缺少 scrcpy-server")
        }
        let localSize = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? -1
        let s = try AdbSocket.open(device.endpoint, serial: device.serial, service: "exec:stat -c %s \(Self.serverRemotePath) 2>/dev/null")
        let remoteSize = Int(String(decoding: s.readToEnd(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -2
        s.close()
        if remoteSize == localSize { return }
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        let client = device.client
        Task.detached {
            do { try await client.push(local, to: Self.serverRemotePath) } catch { err = error }
            sem.signal()
        }
        sem.wait()
        if let err { throw err }
    }

    // MARK: 控制

    func send(_ msg: ControlMessage) {
        let data = msg.data
        controlQueue.async { [weak self] in
            try? self?.controlSocket?.write(data)
        }
    }

    /// Mac → 手機剪貼簿；paste = true 時同時貼上
    func setClipboard(_ text: String, paste: Bool) {
        clipboardSeq += 1
        send(.setClipboard(sequence: clipboardSeq, paste: paste, text: text))
    }

    private func startControlReader(_ s: AdbSocket) {
        Thread.detachNewThread { [weak self] in
            do {
                while true {
                    let type = try s.readExact(1)[0]
                    switch type {
                    case 0:   // 剪貼簿
                        let len = Int(try s.readExact(4).be32(0))
                        let text = String(decoding: try s.readExact(len), as: UTF8.self)
                        DispatchQueue.main.async { self?.onDeviceClipboard?(text) }
                    case 1:   // ack clipboard
                        _ = try s.readExact(8)
                    case 2:   // uhid output
                        let h = try s.readExact(4)
                        let size = Int(UInt16(h[2]) << 8 | UInt16(h[3]))
                        _ = try s.readExact(size)
                    default:
                        return
                    }
                }
            } catch {}
        }
    }

    // MARK: 音訊

    private func startAudio(_ s: AdbSocket) {
        Thread.detachNewThread { [weak self] in
            guard let codec = try? s.readExact(4).be32(0) else { return }
            if codec == 0 || codec == 1 { NSLog("[PhoneCentre] 裝置不支援音訊轉送"); return }
            let player = AudioPlayer()
            self?.audioPlayer = player
            while let header = try? s.readExact(12) {
                let size = Int(header.be32(8))
                guard let packet = try? s.readExact(size) else { break }
                if header.be64(0) & (1 << 63) != 0 { continue }
                player.push(packet)
            }
            player.stop()
        }
    }

    var audioVolume: Float {
        get { audioPlayer?.volume ?? 1 }
        set { audioPlayer?.volume = newValue }
    }

    // MARK: 停止

    func stop() {
        stopped = true
        if config.screenOff { send(.setDisplayPower(true)) }
        controlQueue.async { [self] in
            videoSocket?.close()
            audioSocket?.close()
            controlSocket?.close()
            shellSocket?.close()
            audioPlayer?.stop()
        }
        setState(.stopped)
    }
}

extension Data {
    func be32(_ off: Int) -> UInt32 {
        let b = [UInt8](self[startIndex + off..<startIndex + off + 4])
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    func be64(_ off: Int) -> UInt64 { UInt64(be32(off)) << 32 | UInt64(be32(off + 4)) }
}
