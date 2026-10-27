import AutoNoteCore
import SwiftUI

/// 機材: connected inputs, the registered and ignored lists (§9.5, §11.2–11.3), countdown and grace seconds.
struct DevicesTab: View {
    let env: AppEnvironment

    @State private var connected: [DeviceIdentity] = []
    @State private var entries: [RegisteredDevice] = []
    @State private var matches: [String: RegistryMatch] = [:]
    @State private var thisMac = MacIdentity(id: "", name: "")
    @State private var startOnModelMatch = false
    @State private var countdownSeconds = 5
    @State private var disconnectGraceSeconds = 30
    @State private var loaded = false
    @State private var saveState: SaveState = .idle
    @State private var actionError: String?

    private var registered: [RegisteredDevice] { entries.filter { $0.disposition == .registered } }
    private var ignored: [RegisteredDevice] { entries.filter { $0.disposition == .ignored } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let actionError {
                    Text(actionError).foregroundStyle(.red)
                }
                Section("接続中の音声機器") {
                    if connected.isEmpty {
                        Text("入力機器が見つかりません").foregroundStyle(.secondary)
                    }
                    ForEach(connected, id: \.deviceUID) { device in
                        HStack {
                            DeviceLabel(name: device.name, transport: device.transport, uid: device.deviceUID, detail: nil)
                            Spacer()
                            connectedActions(device)
                        }
                    }
                }
                Section("登録済み") {
                    if registered.isEmpty { Text("なし").foregroundStyle(.secondary) }
                    ForEach(registered) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                DeviceLabel(name: entry.name, transport: entry.transport, uid: entry.deviceUID,
                                            detail: "登録した Mac: \(entry.registeredOn.name)")
                                Spacer()
                                if entry.registeredOn.id != thisMac.id {
                                    Button("この Mac で再登録") { perform { try await reRegister(entry) } }
                                }
                                Button("無視にする") {
                                    perform { try await env.registry.setDisposition(entryID: entry.id, .ignored) }
                                }
                                Button("削除") { perform { try await env.registry.remove(entryID: entry.id) } }
                            }
                            Toggle("同じ型番の機材でも開始する", isOn: Binding(
                                get: { entry.startOnModelMatch },
                                set: { on in perform { try await env.registry.setStartOnModelMatch(entryID: entry.id, on) } }))
                            .font(.caption)
                        }
                    }
                }
                Section("無視") {
                    if ignored.isEmpty { Text("なし").foregroundStyle(.secondary) }
                    ForEach(ignored) { entry in
                        HStack {
                            DeviceLabel(name: entry.name, transport: entry.transport, uid: entry.deviceUID,
                                        detail: "登録した Mac: \(entry.registeredOn.name)")
                            Spacer()
                            Button("無視を解除") {
                                perform { try await env.registry.setDisposition(entryID: entry.id, .registered) }
                            }
                            Button("削除") { perform { try await env.registry.remove(entryID: entry.id) } }
                        }
                    }
                }
                Section("自動録音") {
                    Toggle("新しく登録する機材は、同じ型番の別の機材でも開始する", isOn: $startOnModelMatch)
                    SecondsField(title: "開始までのカウントダウン", value: $countdownSeconds, range: 0...30)
                    SecondsField(title: "切断してから止めるまでの猶予", value: $disconnectGraceSeconds, range: 5...300)
                    Text("カウントダウンは 0〜30 秒、猶予は 5〜300 秒です。範囲の外の値は保存するときに近い端の値になります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            SaveBar(state: saveState, disabled: !loaded) { save() }
        }
        .task { await load() }
    }

    @ViewBuilder private func connectedActions(_ device: DeviceIdentity) -> some View {
        switch matches[device.deviceUID] ?? .unknown {
        case .registered:
            Text("登録済み").foregroundStyle(.secondary)
        case .ignored:
            Text("無視").foregroundStyle(.secondary)
        case .reRegistrationSuggested:
            Button("この Mac で再登録") { perform { try await registerConnected(device) } }
        case .unknown:
            if device.isAutoRecordCandidate {
                Button("登録") { perform { try await registerConnected(device) } }
                Button("無視") { perform { try await env.registry.ignore(device) } }
            }
        }
    }

    private func load() async {
        await env.registry.reload()
        await refreshDevices()
        if let s = try? await env.settings.load() {
            startOnModelMatch = s.startOnModelMatch
            countdownSeconds = s.countdownSeconds
            disconnectGraceSeconds = s.disconnectGraceSeconds
            loaded = true
        } else {
            saveState = .failed("settings.json を読めません")
        }
    }

    private func refreshDevices() async {
        thisMac = SystemMacIdentityProvider().current()
        connected = await env.monitor.connected()
        entries = await env.registry.entries()
        var m: [String: RegistryMatch] = [:]
        for device in connected { m[device.deviceUID] = await env.registry.match(device) }
        matches = m
    }

    private func perform(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                actionError = nil
            } catch {
                actionError = "機材の登録を変更できません（\(String(describing: error))）"
            }
            await refreshDevices()
        }
    }

    private func registerConnected(_ device: DeviceIdentity) async throws {
        let s = try await env.settings.load()
        try await env.registry.register(device, startOnModelMatchDefault: s.startOnModelMatch)
    }

    /// The entry was made on another Mac. When the device is connected here under other identifiers, register what
    /// this Mac sees; otherwise replace the entry with one made on this Mac from the stored values.
    private func reRegister(_ entry: RegisteredDevice) async throws {
        if let live = connected.first(where: { matches[$0.deviceUID] == .reRegistrationSuggested(entryID: entry.id) }) {
            try await env.registry.register(live, startOnModelMatchDefault: entry.startOnModelMatch)
        } else {
            try await replaceWithThisMac(entry)
        }
    }

    /// `register` keeps an existing entry's Mac, so the entry is removed and added again from this Mac.
    private func replaceWithThisMac(_ entry: RegisteredDevice) async throws {
        let identity = DeviceIdentity(name: entry.name, deviceUID: entry.deviceUID, modelUID: entry.modelUID,
                                      transport: entry.transport, inputChannels: 0, uidKind: entry.uidKind)
        try await env.registry.remove(entryID: entry.id)
        let added = try await env.registry.register(identity, startOnModelMatchDefault: entry.startOnModelMatch)
        if added.startOnModelMatch != entry.startOnModelMatch {
            try await env.registry.setStartOnModelMatch(entryID: added.id, entry.startOnModelMatch)
        }
    }

    private func save() {
        let model = startOnModelMatch, countdown = countdownSeconds, grace = disconnectGraceSeconds
        Task {
            do {
                let (saved, _) = try await SettingsSaving.save(env) {
                    $0.startOnModelMatch = model
                    $0.countdownSeconds = countdown
                    $0.disconnectGraceSeconds = grace
                }
                countdownSeconds = saved.countdownSeconds
                disconnectGraceSeconds = saved.disconnectGraceSeconds
                saveState = .saved
            } catch {
                saveState = .failed(SettingsSaving.message(error))
            }
        }
    }
}

private struct DeviceLabel: View {
    let name: String
    let transport: DeviceTransport
    let uid: String
    let detail: String?

    private var transportName: String {
        switch transport {
        case .builtin: "内蔵"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .aggregate: "機器セット"
        case .virtual: "仮想"
        case .unknown: "不明"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text("\(transportName) ・ \(uid)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A number field with a stepper. The field accepts any integer; `SettingsNormalizer` brings it into range on save.
struct SecondsField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Stepper(title, value: $value, in: range).labelsHidden()
                Text("秒")
            }
        }
    }
}
