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

    /// The sheet keeps the definition as it was when it opened, not a list index: the file may change while the
    /// sheet is open (CLI import, an editor), so the save finds it again by value in a fresh read.
    private struct EditTarget: Identifiable {
        /// Nil for a new definition.
        let original: AutomationDefinition?
        let id = UUID()
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
                            editing = EditTarget(original: nil)
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
                        RunRow(run: run).id(run.logDirectory.isEmpty ? "\(run.name)-\(run.startedAt)" : run.logDirectory)
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
            AutomationEditSheet(definition: target.original ?? AutomationDefinition(name: "", on: .minutesGenerated, command: ""),
                                others: Self.removingFirst(target.original, from: definitions)) { edited in
                save(edited, replacing: target.original)
            } onCancel: {
                editing = nil
            }
        }
    }

    @ViewBuilder private func definitionRow(_ index: Int, _ item: LoadedAutomation) -> some View {
        let d = item.definition
        HStack(alignment: .top) {
            Toggle("有効", isOn: Binding(get: { d.enabled }, set: { on in
                mutate(d) { $0[$1].enabled = on }
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
            Button("編集") { editing = EditTarget(original: d) }
                .disabled(locked)
            Button("削除") { mutate(d) { $0.remove(at: $1) } }
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

    private static func removingFirst(_ d: AutomationDefinition?, from list: [AutomationDefinition]) -> [AutomationDefinition] {
        var out = list
        if let d, let i = out.firstIndex(of: d) { out.remove(at: i) }
        return out
    }

    /// The sheet's 保存: re-read the file, find the original again by value and validate against the fresh list.
    /// Returns the message to show in the sheet when the save is refused (the sheet then stays open).
    private func save(_ edited: AutomationDefinition, replacing original: AutomationDefinition?) -> String? {
        let fresh = env.automationsFile.load()
        guard !fresh.disabledByPermission else { loadResult = fresh; return AutomationsFile.permissionWarning }
        do {
            let list = try AutomationDraft.applying(edited, replacing: original, in: fresh.items.map(\.definition))
            if let failure = write(list) { return failure }
            editing = nil
            return nil
        } catch {
            loadResult = fresh
            return SettingsSaving.message(error)
        }
    }

    /// A row's toggle or 削除: applied to a fresh read, at the row's definition found again by value. When it is gone
    /// (changed elsewhere) nothing is written and the list is refreshed.
    private func mutate(_ row: AutomationDefinition, _ change: (inout [AutomationDefinition], Int) -> Void) {
        let fresh = env.automationsFile.load()
        var list = fresh.items.map(\.definition)
        guard !fresh.disabledByPermission, let index = list.firstIndex(of: row) else {
            loadResult = fresh
            message = "この Automation はほかで変更されました。一覧を読み直しました"
            return
        }
        change(&list, index)
        message = write(list)
    }

    /// Saves `list` and reloads; returns the error text on failure.
    @discardableResult
    private func write(_ list: [AutomationDefinition]) -> String? {
        defer { loadResult = env.automationsFile.load() }
        do {
            try env.automationsFile.save(list)
            return nil
        } catch {
            return "automations.json に書き込めません（\((error as NSError).localizedDescription)）"
        }
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
            message = "読み込めません（\(Self.importError(error))）"
        }
    }
}

extension AutomationsTab {
    /// `importReplacing` throws `AutomationsFile`'s parse failure (its `message` says what is wrong with the JSON)
    /// or a read error (`localizedDescription`).
    fileprivate static func importError(_ error: any Error) -> String {
        if let parse = Mirror(reflecting: error).children.first(where: { $0.label == "message" })?.value as? String {
            return parse
        }
        return (error as NSError).localizedDescription
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

    /// The last lines of `stdout.txt` / `stderr.txt`, read once off the main actor (the files are unbounded).
    private struct Tails: Equatable, Sendable {
        var stdout: String?
        var stderr: String?
    }

    @State private var tails: Tails?

    /// At most the last 4096 bytes: seek to the end minus 4096 and read from there.
    nonisolated private static func tail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let start = end > 4096 ? end - 4096 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(10).joined(separator: "\n")
    }

    nonisolated private static func loadTails(_ directory: String) async -> Tails {
        await Task.detached(priority: .utility) {
            guard !directory.isEmpty else { return Tails() }
            let dir = URL(filePath: directory, directoryHint: .isDirectory)
            return Tails(stdout: tail(dir.appending(path: "stdout.txt")), stderr: tail(dir.appending(path: "stderr.txt")))
        }.value
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let tails {
                    if let out = tails.stdout { LogTail(title: "stdout", text: out) }
                    if let err = tails.stderr { LogTail(title: "stderr", text: err) }
                } else {
                    ProgressView().controlSize(.small)
                }
                if !run.logDirectory.isEmpty {
                    Button("ログのフォルダを開く") {
                        NSWorkspace.shared.open(URL(filePath: run.logDirectory, directoryHint: .isDirectory))
                    }
                }
            }
            // Only while expanded; again when this row shows another run.
            .task(id: run.logDirectory) {
                tails = nil
                tails = await Self.loadTails(run.logDirectory)
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
    /// Returns the refusal to show, nil when saved.
    let onSave: (AutomationDefinition) -> String?
    let onCancel: () -> Void
    @State private var refusal: String?

    init(definition: AutomationDefinition, others: [AutomationDefinition],
         onSave: @escaping (AutomationDefinition) -> String?, onCancel: @escaping () -> Void) {
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
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { refusal = onSave(draft.definition) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
