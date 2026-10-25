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
    @Published var dnd = false
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
        if let z = try? await c.shell("settings get global zen_mode") { dnd = (Int(z.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) != 0 }
    }

    /// 請勿打擾：開 = 只允許重要的打擾（priority），關 = 全部通知
    func setDnd(_ on: Bool) {
        dnd = on
        let c = device.client
        Task {
            _ = try? await c.shell("cmd notification set_dnd \(on ? "priority" : "off")")
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let z = try? await c.shell("settings get global zen_mode") { dnd = (Int(z.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) != 0 }
            if let r = await currentRinger() { ringer = r }
        }
    }

    /// 顯示用的音量數字 0～150（把手機的 0～max 格換算過去）
    var displayVolume: Int { Int((Double(volume) / Double(max(maxVolume, 1)) * 150).rounded()) }
    /// 超過 120 太大聲
    var isLoud: Bool { displayVolume > 120 }

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
    @ObservedObject private var settings = AppSettings.shared

    private var phoneMuted: Bool { settings.muteDeviceWhenForwarding }

    /// 手機是否同時發聲：關閉「傳到 Mac 時手機靜音」。音源在連線時決定，所以要重新連線才會生效
    private func setPhonePlayback(_ on: Bool) {
        settings.data.muteDeviceWhenForwarding = !on
        model.pendingChange("正在變更聲音輸出…")
        model.restart()
    }

    init(model: MirrorModel) {
        self.model = model
        _state = StateObject(wrappedValue: SoundState(device: model.device))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("聲音").font(.headline)

            VStack(alignment: .leading, spacing: 10) {
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
                        .tint(state.isLoud ? .red : nil)
                    HStack(spacing: 2) {
                        if state.isLoud { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("音量太大，小心聽力") }
                        Text("\(state.displayVolume)").monospacedDigit()
                            .foregroundStyle(state.isLoud ? Color.red : .secondary)
                            .fontWeight(state.isLoud ? .bold : .regular)
                    }
                    .frame(width: 46, alignment: .trailing)
                }
                if !model.isVirtualDisplay {
                    Toggle("從 Mac 播放", isOn: Binding(get: { !model.muted }, set: { _ in model.toggleMute() }))
                        .disabled(!AppSettings.shared.audioEnabled)
                        .help(AppSettings.shared.audioEnabled ? "把手機的聲音傳到 Mac 播放" : "要先在「設定 → 鏡像」開啟「把手機聲音傳到 Mac」")
                    Toggle("從手機播放", isOn: Binding(get: { !phoneMuted }, set: { setPhonePlayback($0) }))
                        .disabled(!AppSettings.shared.audioEnabled)
                        .help("傳到 Mac 時，手機也同時發聲（需要 Android 13 以上）")
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
                Toggle("請勿打擾", isOn: Binding(get: { state.dnd }, set: { state.setDnd($0) }))
            }

        }
        .padding(16)
        .frame(width: 290)
        .task { await state.load() }
    }
}
