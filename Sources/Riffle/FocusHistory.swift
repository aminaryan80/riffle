import AppKit
import ApplicationServices

/// Tracks when each window was last focused, so the switcher can list
/// windows in true most-recently-used order. macOS exposes no "last focused"
/// timestamp, so we build our own while the app runs:
///  - every app activation (workspace notification) records that app's focused window
///  - an AX observer on the frontmost app records focus changes *within* it
///  - every switch made through Riffle records the target directly
final class FocusHistory {
    static let shared = FocusHistory()

    /// Guards `lastFocused` alone. It's written from the main thread (focus
    /// notifications, and every switch we make) but pruned from the background
    /// window sweep, so the two can collide. The rest of this class is
    /// main-thread only.
    private let lock = NSLock()
    private var lastFocused: [CGWindowID: Date] = [:]
    private var started = false
    private var observer: AXObserver?
    private var observedApp: AXUIElement?

    /// Idempotent; call once accessibility access is available.
    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication {
            recordFocusedWindow(of: front)
            watch(front)
        }
    }

    func record(_ windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        lastFocused[windowID] = Date()
    }

    /// A copy of the whole table. Callers that rank a window list want one
    /// consistent view for the duration of a sort, not a lookup per comparison
    /// that could see the table change halfway through.
    func timestamps() -> [CGWindowID: Date] {
        lock.lock()
        defer { lock.unlock() }
        return lastFocused
    }

    /// Drop entries for windows that no longer exist.
    func prune(keeping alive: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        lastFocused = lastFocused.filter { alive.contains($0.key) }
    }

    // MARK: - Focus tracking

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recordFocusedWindow(of: app)
        watch(app)
    }

    private func recordFocusedWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
        if let wid = PrivateAX.windowID(of: ref as! AXUIElement) {
            record(wid)
        }
    }

    /// Move the focused-window observer to the now-frontmost app.
    private func watch(_ app: NSRunningApplication) {
        if let observer {
            // Unregister before dropping the observer, so the old app's AX
            // server stops tracking notifications nobody is listening for.
            if let observedApp {
                AXObserverRemoveNotification(observer, observedApp, kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(observer, observedApp, kAXMainWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            self.observer = nil
            self.observedApp = nil
        }

        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let history = Unmanaged<FocusHistory>.fromOpaque(refcon).takeUnretainedValue()
            if let wid = PrivateAX.windowID(of: element) {
                history.record(wid)
            }
        }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, axApp, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        observedApp = axApp
    }
}
