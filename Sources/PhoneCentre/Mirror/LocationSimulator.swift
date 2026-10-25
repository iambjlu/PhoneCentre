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

    static func stop(_ device: Device) async {
        _ = try? await device.client.shell(
            "cmd location providers remove-test-provider gps; cmd location providers remove-test-provider network", timeout: 10)
    }
}

struct LocationSimulatorSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
    @State private var picked: CLLocationCoordinate2D?
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
                Button("停止模擬") {
                    Task { await LocationSimulator.stop(device); message = "已停止模擬，恢復真實定位" }
                }
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("套用到手機") {
                    guard let picked else { return }
                    busy = true
                    Task {
                        let ok = await LocationSimulator.apply(device, latitude: picked.latitude, longitude: picked.longitude)
                        message = ok ? "已套用" : "套用失敗（手機可能不允許測試定位）"
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
