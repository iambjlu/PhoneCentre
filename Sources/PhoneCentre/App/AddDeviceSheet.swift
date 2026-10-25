import Network
import SwiftUI

struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("無線 ADB").tag(0)
                Text("遠端 PhoneCentre").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            if mode == 0 { WirelessAddView() } else { RemoteAddView() }
            Divider()
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
        }
        .frame(width: 520, height: 520)
    }
}

/// adb connect／adb pair，以及 mDNS 找到的裝置
struct WirelessAddView: View {
    @ObservedObject private var dm = DeviceManager.shared
    @State private var address = ""
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var message = ""
    @State private var busy = false
    @State private var discovered: [(instance: String, type: String, address: String)] = []

    var body: some View {
        Form {
            Section("USB 轉無線") {
                let usb = dm.onlineDevices.filter { !$0.isWireless && !$0.isRemote }
                if usb.isEmpty {
                    Text("用 USB 線接上手機（已開啟 USB 偵錯），就能一鍵切換成無線連線。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(usb) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.displayName)
                            Text("執行 adb tcpip 5555 後自動連線").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("切換為無線") {
                            busy = true
                            Task {
                                message = (await DeviceManager.shared.enableWireless(d)).1
                                busy = false
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
            Section("連線（adb connect）") {
                HStack {
                    TextField("IP:Port，例如 172.20.10.2:5555", text: $address)
                        .onSubmit(connect)
                    Button("連線", action: connect).disabled(address.isEmpty || busy)
                }
                Text("連線成功的裝置會被記住；adb 被關掉或網路斷線後會自動重連。").font(.caption).foregroundStyle(.secondary)
            }
            Section("配對（Android 11 以上的「無線偵錯」）") {
                TextField("配對 IP:Port（手機上「使用配對碼配對裝置」顯示的）", text: $pairAddress)
                HStack {
                    TextField("六位數配對碼", text: $pairCode)
                    Button("配對") {
                        busy = true
                        Task {
                            let r = await AdbClient.pair(pairAddress.trimmingCharacters(in: .whitespaces), code: pairCode)
                            message = r.message
                            busy = false
                            await scan()
                        }
                    }
                    .disabled(pairAddress.isEmpty || pairCode.isEmpty || busy)
                }
            }
            Section {
                if discovered.isEmpty {
                    Text("沒有找到。請確認手機已開啟「無線偵錯」且和 Mac 在同一個網路。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(discovered, id: \.address) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.instance).lineLimit(1)
                            Text("\(s.address) · \(s.type.contains("pairing") ? "等待配對" : "可連線")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.type.contains("pairing") {
                            Button("填入配對位址") { pairAddress = s.address }
                        } else {
                            Button("連線") { address = s.address; connect() }
                        }
                    }
                }
            } header: {
                HStack { Text("在區域網路上找到的裝置"); Spacer(); Button("重新整理") { Task { await scan() } }.buttonStyle(.link) }
            }
            if !message.isEmpty {
                Text(message).font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task { await scan() }
    }

    private func connect() {
        busy = true
        Task {
            let (_, msg) = await DeviceManager.shared.connect(address)
            message = msg
            busy = false
        }
    }

    private func scan() async { discovered = await AdbClient.mdnsServices() }
}

/// 加入其他電腦上的 PhoneCentre
struct RemoteAddView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var remote = RemoteManager.shared
    @StateObject private var browser = PhoneCentreBrowser()
    @State private var name = ""
    @State private var host = ""
    @State private var port = "47500"
    @State private var password = ""
    @State private var editing: RemoteHost?

    var body: some View {
        Form {
            Section("新增") {
                TextField("名稱", text: $name)
                TextField("主機（IP 或網域）", text: $host)
                TextField("Port", text: $port)
                SecureField("密碼", text: $password)
                Button("加入") {
                    let h = RemoteHost(name: name.isEmpty ? host : name, host: host, port: Int(port) ?? 47_500)
                    settings.setSecret(h.secretKey, password)
                    settings.remoteHosts.append(h)
                    RemoteManager.shared.apply()
                    name = ""; host = ""; password = ""
                }
                .disabled(host.isEmpty || password.isEmpty)
                Text("連線使用 TLS 加密，密碼不會以明碼傳送。對方需要在「設定 → 分享」開啟分享。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !browser.found.isEmpty {
                Section("區域網路上的 PhoneCentre") {
                    ForEach(browser.found, id: \.self) { n in
                        HStack {
                            Text(n)
                            Spacer()
                            Button("填入") { name = n; host = n.replacingOccurrences(of: " ", with: "-") + ".local" }
                        }
                    }
                }
            }
            Section("已加入") {
                ForEach(settings.remoteHosts) { h in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(h.name)
                            Text("\(h.host):\(h.port) · \(remote.status[h.id] ?? "未連線")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重連") { remote.reconnect(h) }
                        Button("編輯…") { editing = h }
                        Button(role: .destructive) {
                            settings.remoteHosts.removeAll { $0.id == h.id }
                            settings.setSecret(h.secretKey, nil)
                            remote.apply()
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { RemoteHostEditSheet(host: $0) }
    }
}

/// 用 Bonjour 找區域網路上開啟分享的 PhoneCentre
final class PhoneCentreBrowser: ObservableObject {
    @Published var found: [String] = []
    private var browser: NWBrowser?

    init() {
        let b = NWBrowser(for: .bonjour(type: SecureChannel.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case let .service(name, _, _, _) = r.endpoint { return name }
                return nil
            }
            let mine = Host.current().localizedName
            DispatchQueue.main.async { self?.found = names.filter { $0 != mine }.sorted() }
        }
        b.start(queue: .main)
        browser = b
    }

    deinit { browser?.cancel() }
}

/// 編輯已加入的遠端 PhoneCentre
struct RemoteHostEditSheet: View {
    let host: RemoteHost
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var name = ""
    @State private var address = ""
    @State private var port = ""
    @State private var password = ""

    var body: some View {
        Form {
            TextField("名稱", text: $name)
            TextField("主機（IP 或網域）", text: $address)
            TextField("Port", text: $port)
            SecureField("密碼（留空表示不變）", text: $password)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存並重新連線") {
                    if let i = settings.remoteHosts.firstIndex(where: { $0.id == host.id }) {
                        settings.remoteHosts[i].name = name.isEmpty ? address : name
                        settings.remoteHosts[i].host = address
                        settings.remoteHosts[i].port = Int(port) ?? 47_500
                    }
                    if !password.isEmpty { settings.setSecret(host.secretKey, password) }
                    RemoteManager.shared.apply()
                    if let h = settings.remoteHosts.first(where: { $0.id == host.id }) { RemoteManager.shared.reconnect(h) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { name = host.name; address = host.host; port = String(host.port) }
    }
}
