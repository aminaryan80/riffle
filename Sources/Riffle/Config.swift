import AppKit

enum Scope: String, Codable, CaseIterable {
    case activeScreen
    case allScreens
    case activeApp

    var label: String {
        switch self {
        case .activeScreen: return "Windows on the active monitor"
        case .allScreens: return "Windows on all monitors"
        case .activeApp: return "Windows of the current app"
        }
    }
}

struct KeyBinding: Codable {
    var key: String
    var modifiers: [String]
    var scope: Scope
}

struct ConfigFile: Codable {
    var bindings: [KeyBinding]
    var excludedApps: [String]?
    // Appearance. Optional so older config files decode with defaults.
    var listScale: Double?
    var backgroundOpacity: Double?
}

struct ResolvedBinding {
    let keyCode: Int64
    let flags: CGEventFlags
    let scope: Scope
}

final class Config {
    static let shared = Config()

    /// Raw bindings as stored on disk (what the Settings UI edits).
    private(set) var fileBindings: [KeyBinding] = []

    /// Excluded apps, stored as bundle identifiers (app names as fallback).
    ///
    /// Guarded, unlike everything else here: the background window sweep reads
    /// this while the Settings window can be editing it on the main thread.
    var excludedApps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _excludedApps
    }
    private var _excludedApps: [String] = []
    private let lock = NSLock()
    /// Bindings resolved to key codes/flags, used by the event tap.
    private(set) var bindings: [ResolvedBinding] = []

    /// Multiplier over the switcher's dynamic row sizing (1 = default range).
    private(set) var listScale: Double = 1.0
    /// Panel background solidity: 0 = fully glassy (blur), 1 = solid/opaque.
    private(set) var backgroundOpacity: Double = 0.0

    static let listScaleRange: ClosedRange<Double> = 0.96...1.44
    static let backgroundOpacityRange: ClosedRange<Double> = 0.0...1.0

    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Riffle", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("config.json")

    static let defaultBindings = [
        KeyBinding(key: "tab", modifiers: ["cmd"], scope: .activeScreen),
        KeyBinding(key: "`", modifiers: ["cmd"], scope: .allScreens),
        KeyBinding(key: "tab", modifiers: ["option"], scope: .activeApp),
    ]

    func load() {
        let exists = FileManager.default.fileExists(atPath: Config.fileURL.path)
        if exists,
           let data = try? Data(contentsOf: Config.fileURL),
           let file = try? JSONDecoder().decode(ConfigFile.self, from: data) {
            fileBindings = file.bindings
            setExcludedApps(file.excludedApps ?? [])
            listScale = Config.clampScale(file.listScale ?? listScale)
            backgroundOpacity = Config.clampOpacity(file.backgroundOpacity ?? backgroundOpacity)
        } else {
            fileBindings = Config.defaultBindings
            setExcludedApps([])
            // Write defaults only when no file exists; never clobber a
            // malformed file the user may want to fix by hand.
            if !exists { save() }
        }
        if fileBindings.isEmpty { fileBindings = Config.defaultBindings }
        rebuildResolved()
    }

    private func setExcludedApps(_ apps: [String]) {
        lock.lock()
        defer { lock.unlock() }
        _excludedApps = apps
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = ConfigFile(
            bindings: fileBindings,
            excludedApps: excludedApps,
            listScale: listScale,
            backgroundOpacity: backgroundOpacity
        )
        if let data = try? encoder.encode(file) {
            try? data.write(to: Config.fileURL, options: .atomic)
        }
        rebuildResolved()
    }

    // MARK: - Appearance

    func setListScale(_ value: Double) {
        listScale = Config.clampScale(value)
        save()
    }

    func setBackgroundOpacity(_ value: Double) {
        backgroundOpacity = Config.clampOpacity(value)
        save()
    }

    private static func clampScale(_ v: Double) -> Double {
        min(max(v, listScaleRange.lowerBound), listScaleRange.upperBound)
    }

    private static func clampOpacity(_ v: Double) -> Double {
        min(max(v, backgroundOpacityRange.lowerBound), backgroundOpacityRange.upperBound)
    }

    // MARK: - Editing (used by the Settings window)

    func addBinding(_ binding: KeyBinding) {
        fileBindings.append(binding)
        save()
    }

    func updateBinding(at index: Int, _ binding: KeyBinding) {
        guard fileBindings.indices.contains(index) else { return }
        fileBindings[index] = binding
        save()
    }

    func removeBinding(at index: Int) {
        guard fileBindings.indices.contains(index) else { return }
        fileBindings.remove(at: index)
        save()
    }

    // Both of these drop the lock before calling `save()`: save reads
    // `excludedApps` back through the getter, which takes the same
    // (non-recursive) lock and would deadlock if it were still held.

    func addExcludedApp(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        lock.lock()
        guard !_excludedApps.contains(identifier) else {
            lock.unlock()
            return
        }
        _excludedApps.append(identifier)
        lock.unlock()
        save()
    }

    func removeExcludedApp(at index: Int) {
        lock.lock()
        guard _excludedApps.indices.contains(index) else {
            lock.unlock()
            return
        }
        _excludedApps.remove(at: index)
        lock.unlock()
        save()
    }

    // MARK: - Lookup

    /// Returns the binding matching this key event, or nil.
    /// Shift is treated as the "cycle backwards" modifier unless the binding requires it.
    func binding(keyCode: Int64, flags: CGEventFlags) -> ResolvedBinding? {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let eventMods = flags.intersection(relevant)
        for b in bindings where b.keyCode == keyCode {
            guard eventMods == b.flags.intersection(relevant) else { continue }
            if b.flags.contains(.maskShift) && !flags.contains(.maskShift) { continue }
            return b
        }
        return nil
    }

    private func rebuildResolved() {
        bindings = fileBindings.compactMap { Config.resolve($0) }
    }

    private static func resolve(_ binding: KeyBinding) -> ResolvedBinding? {
        guard let code = keyCodes[binding.key.lowercased()] else {
            NSLog("Riffle: unknown key name '%@' in config, skipping", binding.key)
            return nil
        }
        var flags: CGEventFlags = []
        for name in binding.modifiers {
            switch Config.canonicalModifier(name) {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default:
                NSLog("Riffle: unknown modifier '%@' in config, skipping binding", name)
                return nil
            }
        }
        guard !flags.isEmpty else {
            NSLog("Riffle: binding for '%@' has no modifiers, skipping", binding.key)
            return nil
        }
        return ResolvedBinding(keyCode: code, flags: flags, scope: binding.scope)
    }

    private static func canonicalModifier(_ name: String) -> String {
        switch name.lowercased() {
        case "cmd", "command": return "cmd"
        case "shift": return "shift"
        case "option", "alt", "opt": return "option"
        case "ctrl", "control": return "ctrl"
        default: return name.lowercased()
        }
    }

    // MARK: - Key names <-> key codes (ANSI layout)

    /// Ordered so that the first name for a code is its canonical display name.
    static let keyList: [(name: String, code: Int64)] = [
        ("tab", 48), ("space", 49),
        ("`", 50), ("grave", 50), ("backtick", 50),
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
        ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
        ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23),
        ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ("=", 24), ("-", 27), ("]", 30), ("[", 33), ("'", 39), (";", 41),
        ("\\", 42), (",", 43), ("/", 44), (".", 47),
        ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97),
        ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111),
        ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]

    static let keyCodes: [String: Int64] =
        Dictionary(keyList.map { ($0.name, $0.code) }, uniquingKeysWith: { first, _ in first })

    static let keyNames: [Int64: String] = {
        var names: [Int64: String] = [:]
        for entry in keyList where names[entry.code] == nil {
            names[entry.code] = entry.name
        }
        return names
    }()

    // MARK: - Display

    static func displayString(for binding: KeyBinding) -> String {
        let mods = Set(binding.modifiers.map { canonicalModifier($0) })
        var out = ""
        if mods.contains("ctrl") { out += "⌃" }
        if mods.contains("option") { out += "⌥" }
        if mods.contains("shift") { out += "⇧" }
        if mods.contains("cmd") { out += "⌘" }
        return out + keyDisplay(binding.key)
    }

    static func keyDisplay(_ name: String) -> String {
        switch name.lowercased() {
        case "tab": return "⇥"
        case "space": return "Space"
        case "`", "grave", "backtick": return "`"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return name.uppercased()
        }
    }
}
