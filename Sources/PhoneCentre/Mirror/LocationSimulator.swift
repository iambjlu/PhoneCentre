import MapKit
import SwiftUI

/// 用 Apple 地圖選一個位置，透過 adb 的測試定位提供者（`cmd location providers`）讓手機以為人在那裡
enum LocationSimulator {
    static func apply(_ device: Device, latitude: Double, longitude: Double) async -> Bool {
        let loc = String(format: "%.6f,%.6f", latitude, longitude)
        var script = "appops set com.android.shell android:mock_location allow; appops set android android:mock_location allow; "
        for p in ["gps", "network"] {
            script += "cmd location providers add-test-provider \(p) 2>/dev/null; "
            script += "cmd location providers set-test-provider-enabled \(p) true; "
            script += "cmd location providers set-test-provider-location \(p) --location \(loc) --accuracy 5; "
        }
        guard let out = try? await device.client.shell(script, timeout: 15) else { return false }
        return !out.contains("Exception") && !out.contains("Error")
    }

    /// 只重送位置（模擬中定時呼叫，避免手機改回真實定位）
    static func refresh(_ device: Device, latitude: Double, longitude: Double) async {
        let loc = String(format: "%.6f,%.6f", latitude, longitude)
        let script = ["gps", "network"].map {
            "cmd location providers set-test-provider-location \($0) --location \(loc) --accuracy 5"
        }.joined(separator: "; ")
        let out = (try? await device.client.shell(script, timeout: 10)) ?? ""
        // 測試提供者不見了（例如手機重開）就整組重建
        if out.contains("Exception") || out.contains("not a test provider") {
            _ = await apply(device, latitude: latitude, longitude: longitude)
        }
    }

    static func stop(_ device: Device) async {
        _ = try? await device.client.shell(
            "cmd location providers remove-test-provider gps; cmd location providers remove-test-provider network", timeout: 10)
    }
}

/// 各裝置目前的模擬狀態。模擬由這裡負責維持（每 5 秒重送位置），跟地圖對話框開不開無關，
/// 只有按「停止模擬」才會結束。
@MainActor
final class LocationSimulation: ObservableObject {
    static let shared = LocationSimulation()
    @Published private(set) var active: [String: CLLocationCoordinate2D] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isActive(_ device: Device) -> Bool { active[device.id] != nil }
    func coordinate(for device: Device) -> CLLocationCoordinate2D? { active[device.id] }

    func start(_ device: Device, _ c: CLLocationCoordinate2D) async -> Bool {
        guard await LocationSimulator.apply(device, latitude: c.latitude, longitude: c.longitude) else { return false }
        active[device.id] = c
        tasks[device.id]?.cancel()
        tasks[device.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let cur = self?.active[device.id] else { return }
                await LocationSimulator.refresh(device, latitude: cur.latitude, longitude: cur.longitude)
            }
        }
        return true
    }

    func stop(_ device: Device) async {
        tasks[device.id]?.cancel()
        tasks[device.id] = nil
        active[device.id] = nil
        await LocationSimulator.stop(device)
    }
}

struct LocationSimulatorSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sim = LocationSimulation.shared
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
    @State private var picked: CLLocationCoordinate2D?
    @State private var didLoad = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋地點或地址", text: $query).textFieldStyle(.plain).onSubmit(search)
                if !results.isEmpty {
                    Menu("搜尋結果（\(results.count)）") {
                        ForEach(results, id: \.self) { item in
                            Button(item.name ?? "未命名") { choose(item.placemark.coordinate) }
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(10)
            Divider()
            MapReader { proxy in
                Map(position: $position) {
                    if let picked { Marker("模擬位置", systemImage: "location.fill", coordinate: picked) }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture(coordinateSpace: .local) { pt in
                    if let c = proxy.convert(pt, from: .local) { picked = c }
                }
            }
            Divider()
            HStack {
                if let picked {
                    Text(String(format: "%.5f, %.5f", picked.latitude, picked.longitude)).monospacedDigit()
                } else {
                    Text("點地圖選擇位置").foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if sim.isActive(device) {
                    Button("停止模擬") {
                        Task { await sim.stop(device); message = "已停止模擬，恢復真實定位" }
                    }
                }
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("套用到手機") {
                    guard let picked else { return }
                    busy = true
                    Task {
                        let ok = await sim.start(device, picked)
                        message = ok ? "已套用（關閉視窗後仍會維持模擬）" : "套用失敗（手機可能不允許測試定位）"
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil || busy)
            }
            .padding(10)
        }
        .frame(width: 680, height: 540)
        .onAppear {
            // 重新開啟時顯示目前正在模擬的位置
            guard !didLoad, let c = sim.coordinate(for: device) else { return }
            didLoad = true
            choose(c)
        }
    }

    private func choose(_ c: CLLocationCoordinate2D) {
        picked = c
        position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    }

    private func search() {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        Task {
            let r = try? await MKLocalSearch(request: req).start()
            results = r?.mapItems ?? []
            if let first = results.first { choose(first.placemark.coordinate) }
        }
    }
}
