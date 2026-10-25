import SwiftUI

/// 手機音量：媒體音量滑桿、一鍵靜音媒體、鈴聲模式（靜音／震動／響鈴），全部走 adb shell
@MainActor
final class SoundState: ObservableObject {
    enum Ringer: Int, CaseIterable, Identifiable {
        case silent = 0, vibrate = 1, normal = 2
        var id: Int { rawValue }
        var title: String { ["靜音", "震動", "響鈴"][rawValue] }
        var symbol: String { ["bell.slash.fill", "iphone.radiowaves.left.and.right", "bell.fill"][rawValue] }
        var cmdName: String { ["SILENT", "VIBRATE", "NORMAL"][rawValue] }
    }

    @Published var volume = 0
    @Published var maxVolume = 15
    @Published var ringer: Ringer = .normal
    @Published var message = ""
    private var lastNonZero = 8
    private let device: Device

    init(device: Device) { self.device = device }

    var isMuted: Bool { volume == 0 }

    func load() async {
        let c = device.client
        if let out = try? await c.shell("cmd media_session volume --stream 3 --get 2>&1"),
           let line = out.split(separator: "\n").last(where: { $0.contains("volume is") }) {
            let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 3 { volume = nums[0]; maxVolume = max(nums[2], 1); if volume > 0 { lastNonZero = volume } }
        }
        if let r = await currentRinger() { ringer = r }
    }

    func setVolume(_ v: Int) {
        let v = min(max(v, 0), maxVolume)
        volume = v
        if v > 0 { lastNonZero = v }
        let c = device.client
        Task { _ = try? await c.shell("cmd media_session volume --stream 3 --set \(v)") }
    }

    /// 一鍵靜音媒體音量；再按一次回到靜音前的音量
    func toggleMute() { setVolume(isMuted ? lastNonZero : 0) }

    private func currentRinger() async -> Ringer? {
        guard let out = try? await device.client.shell("dumpsys audio | grep -m1 'mode (external)'") else { return nil }
        if out.contains("SILENT") { return .silent }
        if out.contains("VIBRATE") { return .vibrate }
        if out.contains("NORMAL") { return .normal }
        return nil
    }

    /// 依序嘗試幾種做法，每次都回頭確認手機真的切過去了（各廠牌、各版本的行為不一樣）
    func setRinger(_ mode: Ringer) {
        let old = ringer
        ringer = mode
        message = ""
        let c = device.client
        Task {
            let attempts = [
                "cmd audio set-ringer-mode \(mode.cmdName) 2>&1",
                "service call audio 38 i32 \(mode.rawValue) s16 com.android.shell",
                mode == .normal ? "cmd media_session volume --stream 2 --set 4" : "cmd media_session volume --stream 2 --set 0",
            ]
            for cmd in attempts {
                _ = try? await c.shell(cmd)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if await currentRinger() == mode { return }
            }
            ringer = await currentRinger() ?? old
            message = "手機沒有接受這個模式（可能被請勿打擾或系統限制擋住）"
        }
    }
}

struct SoundPopover: View {
    @ObservedObject var model: MirrorModel
    @StateObject private var state: SoundState

    init(model: MirrorModel) {
        self.model = model
        _state = StateObject(wrappedValue: SoundState(device: model.device))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("聲音").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("媒體音量").foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { state.toggleMute() } label: {
                        Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(state.isMuted ? "取消靜音" : "一鍵靜音")
                    Slider(value: Binding(get: { Double(state.volume) }, set: { state.setVolume(Int($0.rounded())) }),
                           in: 0...Double(state.maxVolume), step: 1)
                        .controlSize(.small)
                    Text("\(state.volume)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("鈴聲模式").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { state.ringer }, set: { state.setRinger($0) })) {
                    ForEach(SoundState.Ringer.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !state.message.isEmpty {
                    Text(state.message).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.isVirtualDisplay && AppSettings.shared.audioEnabled {
                Toggle("Mac 端靜音（手機聲音傳到 Mac 時）", isOn: Binding(get: { model.muted }, set: { _ in model.toggleMute() }))
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 290)
        .task { await state.load() }
    }
}
