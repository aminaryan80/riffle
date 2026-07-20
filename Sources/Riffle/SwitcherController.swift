import AppKit

/// State machine for one switching session: trigger → cycle → commit/cancel.
final class SwitcherController {
    private(set) var isActive = false

    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private var currentScope: Scope?
    private var holdModifiers: CGEventFlags = []
    private let panel = SwitcherPanelController()

    /// How long the shortcut must stay held before the panel appears.
    private static let showDelay: TimeInterval = 0.16
    private var pendingShow: DispatchWorkItem?
    private var currentScreen: NSScreen?

    init() {
        panel.onHover = { [weak self] index in self?.hover(index) }
    }

    /// The cursor moved onto a row: make it the selection, so releasing the
    /// modifiers commits to whatever is under the pointer.
    private func hover(_ index: Int) {
        guard isActive, windows.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        panel.select(index, scroll: false)
    }

    /// A bound hotkey was pressed (possibly repeatedly while held).
    func handleTrigger(binding: ResolvedBinding, backwards: Bool) {
        if isActive && currentScope == binding.scope {
            step(backwards: backwards)
            return
        }

        // Fresh session, or scope change mid-session (e.g. cmd+tab then cmd+`).
        let snap = WindowEnumerator.snapshot()
        let filtered: [WindowInfo]
        switch binding.scope {
        case .activeScreen:
            filtered = snap.windows.filter { snap.activeScreenWindowIDs.contains($0.windowID) }
        case .allScreens:
            filtered = snap.windows
        case .activeApp:
            filtered = snap.windows.filter { $0.pid == snap.frontmostPID }
        }
        guard !filtered.isEmpty else {
            if isActive { cancel() }
            return
        }

        windows = filtered
        currentScope = binding.scope
        holdModifiers = binding.flags.subtracting(.maskShift)
        // Start on the *next* window (index 1), like the system switcher;
        // with shift held, start from the back.
        if backwards {
            selectedIndex = windows.count - 1
        } else {
            selectedIndex = windows.count > 1 ? 1 : 0
        }
        isActive = true
        scheduleShow(on: snap.activeScreen)
    }

    /// Holds the panel back for `showDelay` so a quick tap-and-release just
    /// flips to the next window, like the system switcher.
    private func scheduleShow(on screen: NSScreen?) {
        pendingShow?.cancel()
        currentScreen = screen
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.showNow()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func showNow() {
        pendingShow?.cancel()
        pendingShow = nil
        panel.show(windows: windows, selected: selectedIndex, on: currentScreen)
    }

    /// True while every modifier of the active binding is still held.
    func holdStillHeld(flags: CGEventFlags) -> Bool {
        flags.intersection(holdModifiers) == holdModifiers
    }

    func commit() {
        guard isActive else { return }
        let target = windows[selectedIndex]
        reset()
        WindowEnumerator.focus(target)
        FocusHistory.shared.record(target.windowID)
        // Focus just changed and the user may re-trigger immediately; warm the
        // cache now so the next session shows without a synchronous sweep.
        WindowEnumerator.refreshAsync()
    }

    func cancel() {
        guard isActive else { return }
        reset()
        WindowEnumerator.refreshAsync()
    }

    func step(backwards: Bool) {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + (backwards ? -1 : 1) + windows.count) % windows.count
        // A second step means the user is cycling rather than flicking, so the
        // panel earns its place immediately instead of waiting out the delay.
        if pendingShow != nil {
            showNow()
        } else {
            panel.select(selectedIndex)
        }
    }

    private func reset() {
        pendingShow?.cancel()
        pendingShow = nil
        isActive = false
        currentScope = nil
        currentScreen = nil
        windows = []
        panel.hide()
    }
}
