import AutoNoteCore
import SwiftUI

/// The live summary's sections, top to bottom (`LiveSummaryPaneContent.sections`), each opening and closing on its
/// own. `onEdit` receives the question actions; nil makes the questions read-only (no checks either).
struct LiveSummarySections: View {
    let content: LiveSummaryPaneContent
    var onEdit: ((LiveQuestionEdit) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(content.sections, id: \.self) { section in
                CollapsibleSection(section: section, badge: content.badge(section)) {
                    sectionBody(section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sectionBody(_ section: LiveSummarySection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let placeholder = content.placeholder(section) {
                Text(placeholder).foregroundStyle(.secondary)
            }
            switch section {
            case .now:
                if let now = content.now {
                    TranslatedText(original: now, translation: content.nowTranslation)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                }
            case .questions:
                LiveQuestionsList(rows: content.questions, editable: content.editable,
                                  canAdd: content.canAddQuestion, onEdit: onEdit)
            case .todos:
                ForEach(content.todoGroups, id: \.title) { group in
                    Text(group.title)
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    BulletList(items: group.items, translations: group.translations)
                }
            case .decisions:
                BulletList(items: content.decisions, translations: content.decisionTranslations)
            }
        }
    }
}

/// A section's header (chevron, icon, title, badge) and its body while open. The open state is kept per section
/// in the app's defaults, shared by every screen that shows the summary.
private struct CollapsibleSection<Content: View>: View {
    let section: LiveSummarySection
    let badge: String?
    @ViewBuilder let content: Content
    @AppStorage private var expanded: Bool

    init(section: LiveSummarySection, badge: String?, @ViewBuilder content: () -> Content) {
        self.section = section
        self.badge = badge
        self.content = content()
        _expanded = AppStorage(wrappedValue: section.expandedByDefault, section.storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: section.symbol).foregroundStyle(Color.accentColor)
                    Text(section.title).font(.headline)
                    if let badge {
                        Text(badge).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.toggleLabel(expanded: expanded))
            .accessibilityValue(badge ?? "")
            if expanded {
                content.padding(.leading, 18)
            }
        }
    }
}

/// One 「・」 row per item, each with its translation underneath when there is one (index-aligned).
private struct BulletList: View {
    let items: [String]
    var translations: [String?] = []

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("・").foregroundStyle(.secondary)
                TranslatedText(original: item, translation: translations.indices.contains(i) ? translations[i] : nil)
            }
            .textSelection(.enabled)
        }
    }
}

/// 「聞きたいこと」: a check per row, then (editable) 「＋ 聞きたいことを追加」.
struct LiveQuestionsList: View {
    let rows: [LiveQuestionRow]
    let editable: Bool
    let canAdd: Bool
    let onEdit: ((LiveQuestionEdit) -> Void)?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                LiveQuestionRowView(row: row, editable: editable, onEdit: onEdit)
            }
            if editable, let onEdit {
                if adding {
                    AddQuestionField(onAdd: { onEdit(.add($0)) }, onClose: { adding = false })
                } else if canAdd {
                    Button {
                        adding = true
                    } label: {
                        Label(LiveSummaryPresentation.addQuestionTitle, systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                } else {
                    Text(LiveSummaryPresentation.questionLimitNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The one-line field: Return adds and keeps it open for the next; Return on an empty field or Esc closes it.
private struct AddQuestionField: View {
    let onAdd: (String) -> Void
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(LiveSummaryPresentation.addQuestionTitle, text: $text,
                  prompt: Text(LiveSummaryPresentation.addQuestionPrompt))
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return onClose() }
                onAdd(value)
                text = ""
                focused = true
            }
            .onExitCommand(perform: onClose)
            .onAppear { focused = true }
            .accessibilityLabel(LiveSummaryPresentation.addQuestionTitle)
    }
}

/// A question: the check (toggles, marked by hand), the text (double-click edits), and while hovered × (removes).
/// The context menu has 文言を編集 and 削除; VoiceOver gets the same as named actions.
private struct LiveQuestionRowView: View {
    let row: LiveQuestionRow
    let editable: Bool
    let onEdit: ((LiveQuestionEdit) -> Void)?
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                onEdit?(.setAsked(id: row.id, !row.asked))
            } label: {
                Image(systemName: row.asked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.asked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(onEdit == nil)
            .accessibilityLabel(row.toggleLabel)
            .accessibilityValue(row.stateLabel)
            if editing {
                TextField(LiveSummaryPresentation.editTitle, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit {
                        onEdit?(.rename(id: row.id, draft))
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onAppear { fieldFocused = true }
                    .accessibilityLabel(row.editLabel)
            } else {
                Text(row.text)
                    .foregroundStyle(row.asked ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if editable { beginEditing() } }
                    .accessibilityLabel(row.text)
                    .accessibilityValue(row.stateLabel)
            }
            if editable, hovering, !editing {
                Button {
                    onEdit?(.remove(id: row.id))
                } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.deleteLabel)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if editable, onEdit != nil {
                Button(LiveSummaryPresentation.editTitle) { beginEditing() }
                Button(LiveSummaryPresentation.deleteTitle, role: .destructive) { onEdit?(.remove(id: row.id)) }
            }
        }
        .accessibilityElement(children: .contain)
        .modifier(QuestionAccessibilityActions(row: row, editable: editable && onEdit != nil,
                                               edit: beginEditing, remove: { onEdit?(.remove(id: row.id)) }))
    }

    private func beginEditing() {
        draft = row.text
        editing = true
    }
}

/// 文言を編集 / 削除 as VoiceOver actions (the hover-only × is out of reach otherwise).
private struct QuestionAccessibilityActions: ViewModifier {
    let row: LiveQuestionRow
    let editable: Bool
    let edit: () -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        if editable {
            content
                .accessibilityAction(named: Text(row.editLabel), edit)
                .accessibilityAction(named: Text(row.deleteLabel), remove)
        } else {
            content
        }
    }
}

/// The recording screen's right pane: 「✦ ライブ要約」 with the status and age at the right end, and the sections
/// in a scroll view that uses the full height.
struct LiveSummaryPane: View {
    let content: LiveSummaryPaneContent
    var onEdit: ((LiveQuestionEdit) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: "sparkles", title: LiveSummaryPresentation.paneTitle) {
                if let status = content.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let updated = content.updated {
                    Text(updated).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Divider()
            ScrollView {
                LiveSummarySections(content: content, onEdit: onEdit)
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A pane's header row: icon, title, and whatever goes at the right end.
struct PaneHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// After the stop (processing, minutes missing): the same sections, read-only except the checks, in a capped band.
struct StoredLiveSummaryCard: View {
    let content: LiveSummaryPaneContent
    var onEdit: ((LiveQuestionEdit) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(symbol: "sparkles", title: LiveSummaryPresentation.paneTitle) { EmptyView() }
            CappedScrollView(maxHeight: LiveSummaryLayout.stackedMaxHeight) {
                LiveSummarySections(content: content, onEdit: onEdit)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A scroll view as tall as its content up to `maxHeight` (a plain `maxHeight` frame would grow to the cap).
struct CappedScrollView<Content: View>: View {
    let maxHeight: Double
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, CGFloat(maxHeight)))
    }
}

/// 「聞きたいこと」 alone, in a rounded panel: the draft before recording, or a recording with summaries off.
struct QuestionsPanel: View {
    let title: String
    var note: String?
    let content: LiveSummaryPaneContent
    let onEdit: (LiveQuestionEdit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: LiveSummarySection.questions.symbol).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                if let badge = content.badge(.questions) {
                    Text(badge).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let placeholder = content.placeholder(.questions) {
                Text(placeholder).foregroundStyle(.secondary)
            }
            LiveQuestionsList(rows: content.questions, editable: true, canAdd: content.canAddQuestion, onEdit: onEdit)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// The draft written before recording, in the toolbar's popover and on the empty screen.
struct QuestionsDraftPanel: View {
    let model: AppModel

    var body: some View {
        QuestionsPanel(title: LiveSummaryPresentation.draftTitle, note: LiveSummaryPresentation.draftNote,
                       content: LiveSummaryPresentation.questionsOnly(model.questions(.draft))) { edit in
            Task { await model.perform(.editQuestion(edit, in: .draft)) }
        }
    }
}

/// The post-stop card of a meeting: this launch's newest result (or the stored one) and its questions, whose checks
/// still toggle; nothing when there is neither.
struct StoredLiveSummary: View {
    let model: AppModel
    let id: MeetingID
    let stored: LiveSummaryState?
    /// The meeting's live summary translation (`MeetingTranslation.liveSummary`).
    var translation: SummaryTranslationDocument?

    var body: some View {
        if let content = LiveSummaryPresentation.stored(
            state: model.liveSummary(for: id)?.state ?? stored, questions: model.questions(.meeting(id)),
            translation: TranslationPresentation.summaryTranslation(translation, shown: model.translationShown)) {
            StoredLiveSummaryCard(content: content) { edit in
                guard case .setAsked = edit else { return }   // read-only otherwise
                Task { await model.perform(.editQuestion(edit, in: .meeting(id))) }
            }
        }
    }
}
