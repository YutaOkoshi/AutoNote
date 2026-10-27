import AppKit
import AutoNoteCore
import SwiftUI
import UniformTypeIdentifiers

/// Automations (§14): the definitions in `automations.json` (add, edit, delete), a manual run, the run log and
/// export / import. A file others can write to disables everything; that and every other load warning sit in a
/// band at the top (§14.2).
struct AutomationsTab: View {
    let env: AppEnvironment

    @State private var loadResult = AutomationsLoadResult()
    @State private var runs: [AutomationRunRecord] = []
    @State private var editing: EditTarget?
    @State private var runMeetingID: String?
    @State private var message: String?
    @State private var running: String?

    private struct EditTarget: Identifiable {
        /// Index in the current list, nil for a new definition.
        let index: Int?
        let definition: AutomationDefinition
        var id: String { index.map(String.init) ?? "new" }
    }

    private var definitions: [AutomationDefinition] { loadResult.items.map(\.definition) }

    /// While the file is writable by others nothing is edited here: saving would make it 0600 again and so trust
    /// commands someone else may have written. The band says how to fix it.
    private var locked: Bool { loadResult.disabledByPermission }

    var body: some View {
        VStack(spacing: 0) {
            if !loadResult.warnings.isEmpty {
                WarningBand(lines: loadResult.warnings, severe: loadResult.disabledByPermission)
            }
            Form {
                Section {
                    if loadResult.items.isEmpty { Text("Automation はありません").foregroundStyle(.secondary) }
                    ForEach(Array(loadResult.items.enumerated()), id: \.offset) { index, item in
                        definitionRow(index, item)
                    }
                    HStack {
                        Button("追加", systemImage: "plus") {
                            editing = EditTarget(index: nil, definition: AutomationDefinition(name: "", on: .minutesGenerated,
                                                                                              command: ""))
                        }
                        .disabled(locked)
                        Spacer()
                        Button("書き出す…") { exportFile() }
                        Button("読み込む…") { importFile() }
                    }
                } header: {
                    Text("定義")
                } footer: {
                    Text("コマンドは /bin/zsh -lc で動きます。会議の情報は環境変数 AUTONOTE_* と標準入力の JSON で渡します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("手動実行") {
                    Picker("会議", selection: $runMeetingID) {
                        Text("選んでください").tag(String?.none)
                        ForEach(env.model.meetings) { row in
                            Text("\(row.startedAt.formatted(date: .numeric, time: .shortened))  \(row.title)")
                                .tag(String?.some(row.id))
                        }
                    }
                    if runMeetingID == nil {
                        Text("会議を選ぶと、各 Automation の「実行」が使えます。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message { Text(message).font(.caption) }
                }
                Section {
                    if runs.isEmpty { Text("まだ実行していません").foregroundStyle(.secondary) }
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        RunRow(run: run)
                    }
                } header: {
                    HStack {
                        Text("実行ログ（新しい順に 50 件）")
                        Spacer()
                        Button("更新") { Task { await refreshRuns() } }.buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task { await reload() }
        .task { await followRuns() }
        .onWindowBecameKey { Task { await reload() } }
        .sheet(item: $editing) { target in
            AutomationEditSheet(definition: target.definition,
                                others: definitions.enumerated().filter { $0.offset != target.index }.map(\.element)) { saved in
                editing = nil
                var list = definitions
                if let index = target.index { list[index] = saved } else { list.append(saved) }
                write(list)
            } onCancel: {
                editing = nil
            }
        }
    }

    @ViewBuilder private func definitionRow(_ index: Int, _ item: LoadedAutomation) -> some View {
        let d = item.definition
        HStack(alignment: .top) {
            Toggle("有効", isOn: Binding(get: { d.enabled }, set: { on in
                var list = definitions
                list[index].enabled = on
                write(list)
            }))
            .labelsHidden()
            .disabled(locked)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name)
                Text("\(TriggerName.of(d.on)) ・ タイムアウト \(d.timeoutSec) 秒").font(.caption).foregroundStyle(.secondary)
                Text(d.command).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                if let problem = item.problem, !loadResult.disabledByPermission {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(running == d.name ? "実行中…" : "実行") { run(d.name) }
                .disabled(runMeetingID == nil || !item.isRunnable || running != nil)
            Button("編集") { editing = EditTarget(index: index, definition: d) }
                .disabled(locked)
            Button("削除") {
                var list = definitions
                list.remove(at: index)
                write(list)
            }
            .disabled(locked)
        }
    }

    private func reload() async {
        loadResult = env.automationsFile.load()
        await refreshRuns()
        if runMeetingID == nil { runMeetingID = env.model.meetings.first?.id }
    }

    private func refreshRuns() async {
        runs = await env.ports.automations.recentRuns(limit: 50)
    }

    /// Runs finished by the queue while the tab is open appear without a manual refresh.
    private func followRuns() async {
        for await _ in await env.ports.automations.records() {
            await refreshRuns()
        }
    }

    private func write(_ list: [AutomationDefinition]) {
        do {
            try env.automationsFile.save(list)
            message = nil
        } catch {
            message = "automations.json に書き込めません（\((error as NSError).localizedDescription)）"
        }
        loadResult = env.automationsFile.load()
    }

    private func run(_ name: String) {
        guard let id = runMeetingID else { return }
        running = name
        message = "\(name) を実行しています…"
        Task {
            do {
                let record = try await env.ports.automations.run(name: name, meetingID: MeetingID(rawValue: id))
                message = record.succeeded ? "\(name): 成功" : "\(name): \(RunRow.outcome(record))"
            } catch {
                message = "\(name) を実行できません（\(SettingsSaving.message(error))）"
            }
            running = nil
            await refreshRuns()
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "automations.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try env.automationsFile.export(to: url)
            message = "書き出しました: \(url.path(percentEncoded: false))"
        } catch {
            message = "書き出せません（\((error as NSError).localizedDescription)）"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            loadResult = try env.automationsFile.importReplacing(from: url)
            message = "読み込みました（今の定義は置き換わりました）"
        } catch {
            message = "読み込めません（JSON の配列ではありません）"
        }
    }
}

enum TriggerName {
    static func of(_ t: AutomationTrigger) -> String {
        switch t {
        case .minutesGenerated: "議事録ができたとき"
        case .transcriptOnly: "文字起こしだけで終わったとき"
        case .recordingStarted: "録音を始めたとき"
        case .recordingStopped: "録音を止めたとき"
        }
    }
}

/// The band at the top of the tab (§14.2).
private struct WarningBand: View {
    let lines: [String]
    let severe: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "exclamationmark.triangle.fill").font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(severe ? Color.red.opacity(0.18) : Color.orange.opacity(0.18))
    }
}

/// One `AutomationRunRecord`: time, name, meeting, exit code or timeout, duration, the ends of stdout / stderr and
/// a button that opens the log folder.
private struct RunRow: View {
    let run: AutomationRunRecord
    @State private var expanded = false

    static func outcome(_ r: AutomationRunRecord) -> String {
        if let failure = r.failureMessage { return "開始できませんでした: \(failure)" }
        if r.skippedReason == "already_ran" { return "実行済みのため飛ばしました" }
        if r.timedOut { return "タイムアウト" }
        if let code = r.exitCode { return "終了コード \(code)" }
        return "シグナルで終了"
    }

    private func tail(_ file: String) -> String? {
        guard !run.logDirectory.isEmpty,
              let data = try? Data(contentsOf: URL(filePath: run.logDirectory).appending(path: file)), !data.isEmpty
        else { return nil }
        let lines = String(decoding: data.suffix(4096), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(10).joined(separator: "\n")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let out = tail("stdout.txt") { LogTail(title: "stdout", text: out) }
                if let err = tail("stderr.txt") { LogTail(title: "stderr", text: err) }
                if !run.logDirectory.isEmpty {
                    Button("ログのフォルダを開く") {
                        NSWorkspace.shared.open(URL(filePath: run.logDirectory, directoryHint: .isDirectory))
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: run.succeeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(run.succeeded ? Color.green : (run.skippedReason != nil ? Color.secondary : Color.red))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.startedAt.formatted(date: .numeric, time: .standard))  \(run.name)")
                    Text("会議 \(run.meetingID) ・ \(TriggerName.of(run.event)) ・ \(Self.outcome(run)) ・ \(String(format: "%.1f", run.durationSeconds)) 秒")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LogTail: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.secondary.opacity(0.08))
        }
    }
}

/// Add / edit: name, trigger (4 choices), command, timeout. `AutomationDraft.validate` runs as the user types and
/// its messages sit under the fields; 「保存」 is off while there are any.
private struct AutomationEditSheet: View {
    @State private var draft: AutomationDraft
    let others: [AutomationDefinition]
    let onSave: (AutomationDefinition) -> Void
    let onCancel: () -> Void

    init(definition: AutomationDefinition, others: [AutomationDefinition],
         onSave: @escaping (AutomationDefinition) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: AutomationDraft(definition))
        self.others = others
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var problems: [String] { AutomationDraft.validate(draft.definition, existing: others) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("名前", text: $draft.definition.name)
                Picker("きっかけ", selection: $draft.definition.on) {
                    ForEach(AutomationTrigger.allCases, id: \.self) { t in
                        Text(TriggerName.of(t)).tag(t)
                    }
                }
                Toggle("有効", isOn: $draft.definition.enabled)
                LabeledContent("タイムアウト") {
                    HStack(spacing: 4) {
                        TextField("タイムアウト", value: $draft.definition.timeoutSec, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("秒")
                    }
                }
                LabeledContent("コマンド") {
                    TextEditor(text: $draft.definition.command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .border(.separator)
                }
            }
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(draft.definition) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
