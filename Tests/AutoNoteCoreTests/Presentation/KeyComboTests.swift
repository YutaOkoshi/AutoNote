import Testing
import AutoNoteCore

@Suite struct KeyComboTests {
    @Test func parsesSettingsStrings() {
        #expect(KeyCombo(parsing: "ctrl+option+b") == KeyCombo(keyCode: 11, modifiers: 6144) && KeyCombo(parsing: "ctrl+option+b")?.display == "⌃⌥B")
        #expect(KeyCombo(parsing: "cmd+shift+option+ctrl+a")?.description == "ctrl+option+shift+cmd+a")   // 保存形は ctrl option shift cmd の順
        #expect(KeyCombo(parsing: "cmd+shift+option+ctrl+a")?.display == "⌃⌥⇧⌘A")
        #expect(KeyCombo(parsing: "ctrl+option") == nil && KeyCombo(parsing: "hyper+b") == nil && KeyCombo(parsing: "") == nil)
        #expect(KeyCombo(parsing: "ctrl+a+b") == nil && KeyCombo(parsing: "ctrl++b") == nil)
        #expect(KeyCombo(parsing: "Ctrl+Option+F12") == KeyCombo(keyCode: 111, modifiers: 6144) && KeyCombo(parsing: "cmd+0") == KeyCombo(keyCode: 29, modifiers: 256))
        #expect(KeyCombo(parsing: "ctrl+option+r")?.keyName == "r")
        #expect(KeyCombo(parsing: "ctrl+option+f12")?.display == "⌃⌥F12" && KeyCombo(parsing: "option+cmd+F1")?.description == "option+cmd+f1")
    }

    @Test func defaultShortcuts() {
        // ShortcutBindings(Shortcuts()) → ⌃⌥B / ⌃⌥R（keyCode 15）/ ⌃⌥P（keyCode 35）、duplicates() == []
        let b = ShortcutBindings(Shortcuts())
        #expect(b.combo(for: .bookmark)?.display == "⌃⌥B")
        #expect(b.combo(for: .toggleRecording) == KeyCombo(keyCode: 15, modifiers: 6144) && b.combo(for: .toggleRecording)?.display == "⌃⌥R")
        #expect(b.combo(for: .togglePause) == KeyCombo(keyCode: 35, modifiers: 6144) && b.combo(for: .togglePause)?.display == "⌃⌥P")
        #expect(b.duplicates() == [])
        var s = Shortcuts()
        s[keyPath: ShortcutAction.togglePause.keyPath] = "cmd+p"
        #expect(s.togglePause == "cmd+p" && ShortcutBindings(s).combo(for: .togglePause) == KeyCombo(keyCode: 35, modifiers: 256))
    }

    @Test func validateAndDuplicates() {
        // modifiers 0 や shiftKey だけ → throws .invalid
        #expect(throws: AppCommandError.invalid("⌃ ⌥ ⌘ のどれかを含めてください")) { try KeyCombo(keyCode: 11, modifiers: 0).validate() }
        #expect(throws: AppCommandError.invalid("⌃ ⌥ ⌘ のどれかを含めてください")) { try KeyCombo(keyCode: 11, modifiers: 512).validate() }
        #expect(throws: Never.self) { try KeyCombo(keyCode: 11, modifiers: 512 | 256).validate() }
        // bookmark と togglePause が同じ文字列 → [.bookmark, .togglePause]
        let b = ShortcutBindings(Shortcuts(bookmark: "ctrl+option+b", toggleRecording: "ctrl+option+r", togglePause: "ctrl+option+b"))
        #expect(b.duplicates() == [.bookmark, .togglePause])
        // Unreadable values have no combo and are not duplicates of each other.
        let bad = ShortcutBindings(Shortcuts(bookmark: "hyper+b", toggleRecording: "hyper+b", togglePause: "ctrl+option+p"))
        #expect(bad.combo(for: .bookmark) == nil && bad.duplicates() == [])
        #expect(ShortcutBindings.unreadableMessage("hyper+b") == "読めないショートカット: hyper+b")
    }
}
