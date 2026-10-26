import Foundation

/// A global shortcut as Carbon sees it. Settings store it as a string such as `"ctrl+option+b"`.
public struct KeyCombo: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt32
    /// Carbon modifier bits: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
    public var modifiers: UInt32

    public static let cmdKey: UInt32 = 256
    public static let shiftKey: UInt32 = 512
    public static let optionKey: UInt32 = 2048
    public static let controlKey: UInt32 = 4096

    /// Stored and displayed in this order: ctrl option shift cmd.
    private static let modifierNames: [(name: String, bit: UInt32, symbol: String)] = [
        ("ctrl", controlKey, "⌃"), ("option", optionKey, "⌥"), ("shift", shiftKey, "⇧"), ("cmd", cmdKey, "⌘"),
    ]

    /// ANSI key codes (kVK_ANSI_* / kVK_F*).
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    private static let keyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Modifier words and exactly one key, joined by `+`, case-insensitive. Anything else is nil.
    public init?(parsing: String) {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for word in parsing.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            if let m = Self.modifierNames.first(where: { $0.name == word }) {
                modifiers |= m.bit
            } else if let code = Self.keyCodes[word], key == nil {
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(keyCode: key, modifiers: modifiers)
    }

    private var keyName: String { Self.keyNames[keyCode] ?? "key\(keyCode)" }

    /// The settings form, e.g. `"ctrl+option+b"`.
    public var description: String {
        (Self.modifierNames.filter { modifiers & $0.bit != 0 }.map(\.name) + [keyName]).joined(separator: "+")
    }

    /// The menu form, e.g. `"⌃⌥B"`.
    public var display: String {
        Self.modifierNames.filter { modifiers & $0.bit != 0 }.map(\.symbol).joined() + keyName.uppercased()
    }

    /// Shift alone is not enough for a global shortcut.
    public func validate() throws(AppCommandError) {
        guard modifiers & (Self.controlKey | Self.optionKey | Self.cmdKey) != 0 else {
            throw .invalid("⌃ ⌥ ⌘ のどれかを含めてください")
        }
    }
}

public enum ShortcutAction: String, Sendable, CaseIterable {
    case bookmark, toggleRecording, togglePause

    public var keyPath: WritableKeyPath<Shortcuts, String> {
        switch self {
        case .bookmark: \.bookmark
        case .toggleRecording: \.toggleRecording
        case .togglePause: \.togglePause
        }
    }
}

/// Read-only view of `Shortcuts` for showing and registering hot keys. Saving stays with the `Shortcuts` strings.
public struct ShortcutBindings: Equatable, Sendable {
    private let shortcuts: Shortcuts

    public init(_ s: Shortcuts) { shortcuts = s }

    /// Copy for a settings value that does not parse (it is not registered).
    public static func unreadableMessage(_ raw: String) -> String { "読めないショートカット: \(raw)" }

    public func combo(for action: ShortcutAction) -> KeyCombo? { KeyCombo(parsing: shortcuts[keyPath: action.keyPath]) }

    /// Actions whose combo another action also uses, in `allCases` order. Unreadable values are left out.
    public func duplicates() -> [ShortcutAction] {
        let combos = ShortcutAction.allCases.map { ($0, combo(for: $0)) }
        return combos.filter { action, combo in
            guard let combo else { return false }
            return combos.contains { $0.0 != action && $0.1 == combo }
        }.map(\.0)
    }
}
