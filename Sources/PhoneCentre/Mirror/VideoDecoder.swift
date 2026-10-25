import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import VideoToolbox

/// 把 scrcpy 送來的 H.264（Annex B）封包轉成 CMSampleBuffer，交給 AVSampleBufferDisplayLayer 硬體解碼顯示
final class VideoDecoder {
    private(set) var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    var onSizeChange: ((CGSize) -> Void)?
    var enqueue: ((CMSampleBuffer, _ formatChanged: Bool) -> Void)?
    private var formatChanged = false
    private var captureHandler: ((Data?) -> Void)?
    private let captureLock = NSLock()

    /// 下一個關鍵幀解碼成 PNG 交給 handler；3 秒內沒有關鍵幀就回傳 nil
    func captureNextKeyFrame(_ handler: @escaping (Data?) -> Void) {
        captureLock.lock(); captureHandler = handler; captureLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.captureLock.lock()
            let h = self.captureHandler
            self.captureHandler = nil
            self.captureLock.unlock()
            h?(nil)
        }
    }

    /// 最近一張「不是全黑」的關鍵幀（App 被關掉時拿來當霧化背景）。只有 keepLastFrame 開啟時才解碼。
    var keepLastFrame = false
    private(set) var lastGoodFrame: NSImage?

    private func decode(_ sample: CMSampleBuffer, _ format: CMVideoFormatDescription) -> CGImage? {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        var result: CGImage?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            guard st == noErr, let image else { return }
            let ci = CIImage(cvPixelBuffer: image)
            result = CIContext().createCGImage(ci, from: ci.extent)
        }
        if status == noErr { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        VTDecompressionSessionInvalidate(session)
        return result
    }

    private static func isBlack(_ cg: CGImage) -> Bool {
        var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let ctx = CGContext(data: &px, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        return !stride(from: 0, to: px.count, by: 4).contains { px[$0] > 6 || px[$0 + 1] > 6 || px[$0 + 2] > 6 }
    }

    private func handleKeyFrame(sample: CMSampleBuffer, format: CMVideoFormatDescription) {
        captureLock.lock()
        let h = captureHandler
        captureHandler = nil
        captureLock.unlock()
        guard h != nil || keepLastFrame else { return }
        let cg = decode(sample, format)
        if let h {
            h(cg.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        }
        if keepLastFrame, let cg, !Self.isBlack(cg) {
            lastGoodFrame = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    /// 依 00 00 01 / 00 00 00 01 起始碼切出 NAL units
    static func nalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[start..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { units.append(Data(bytes[start..<n])) }
        if start < 0, n > 0 { units.append(data) }
        return units
    }

    func handleConfig(_ packet: Data) {
        for nal in Self.nalUnits(packet) {
            guard let t = nal.first.map({ $0 & 0x1f }) else { continue }
            if t == 7 { sps = nal }
            if t == 8 { pps = nal }
        }
        rebuildFormat()
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var desc: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else { return }
        let old = format.map { CMVideoFormatDescriptionGetDimensions($0) }
        format = desc
        formatChanged = true
        let dim = CMVideoFormatDescriptionGetDimensions(desc)
        if old?.width != dim.width || old?.height != dim.height {
            onSizeChange?(CGSize(width: Int(dim.width), height: Int(dim.height)))
        }
    }

    func handleFrame(_ packet: Data, pts: UInt64, keyFrame: Bool) {
        var avcc = Data()
        var sawParams = false
        for nal in Self.nalUnits(packet) {
            guard let t = nal.first.map({ $0 & 0x1f }) else { continue }
            switch t {
            case 7: sps = nal; sawParams = true
            case 8: pps = nal; sawParams = true
            case 9: continue    // AUD
            default:
                var len = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &len, count: 4))
                avcc.append(nal)
            }
        }
        if sawParams { rebuildFormat() }
        guard let format, !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sizeArr = [count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let a = attachments.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
            if !keyFrame { a[kCMSampleAttachmentKey_NotSync] = true }
        }
        if keyFrame { handleKeyFrame(sample: sample, format: format) }
        let changed = formatChanged
        formatChanged = false
        enqueue?(sample, changed)
    }
}
