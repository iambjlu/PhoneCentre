import AVFoundation

/// 播放 scrcpy 的 raw 音訊（PCM s16le、雙聲道、48 kHz），用環形緩衝區控制延遲
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = NSLock()
    private var ring: [Int16]
    private var readPos = 0
    private var writePos = 0
    private var filled = 0
    private let capacity: Int
    /// 緩衝超過這個量（frame）就丟掉舊資料，維持低延遲
    private let maxLatencyFrames = 48_000 / 5
    private var started = false

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init() {
        capacity = 48_000 * 2 * 2   // 2 秒雙聲道
        ring = [Int16](repeating: 0, count: capacity)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        source = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            for i in 0..<Int(frameCount) {
                if self.filled >= 2 {
                    l[i] = Float(self.ring[self.readPos]) / 32_768
                    r[i] = Float(self.ring[(self.readPos + 1) % self.capacity]) / 32_768
                    self.readPos = (self.readPos + 2) % self.capacity
                    self.filled -= 2
                } else {
                    l[i] = 0; r[i] = 0
                }
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
    }

    func start() {
        guard !started else { return }
        started = (try? engine.start()) != nil
    }

    func stop() {
        engine.stop()
        started = false
    }

    func push(_ pcm: Data) {
        start()
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            lock.lock()
            for s in samples where filled < capacity {
                ring[writePos] = Int16(littleEndian: s)
                writePos = (writePos + 1) % capacity
                filled += 1
            }
            // 延遲太大就跳到最新（以雙聲道為單位，維持左右聲道對齊）
            let maxSamples = maxLatencyFrames * 2
            if filled > maxSamples {
                let drop = (filled - maxSamples / 2) & ~1
                readPos = (readPos + drop) % capacity
                filled -= drop
            }
            lock.unlock()
        }
    }
}
