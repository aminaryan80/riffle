import AppKit
import ApplicationServices

/// Event-driven cache upkeep: watches each regular app for window creation
/// and prunes on quit. Idle cost is roughly zero — observers only wake when
/// something changes (no polling).
///
/// Deliberately does *not* observe `kAXUIElementDestroyedNotification`: that
/// fires for every menu/button/cell teardown and would spam AX IPC across all
/// apps. Closed windows are dropped cheaply via the CGWindowList diff in
/// `WindowEnumerator.snapshot()`.
final class WindowCacheObserver {
    static let shared = WindowCacheObserver()

    private var started = false
    private var observers: [pid_t: (obs: AXObserver, app: AXUIElement)] = [:]
    private let myPID = ProcessInfo.processInfo.processIdentifier

    /// Idempotent; call once accessibility access is available.
    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        for app in NSWorkspace.shared.runningApplications where isTrackable(app) {
            watch(app)
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isTrackable(app) else { return }
        watch(app)
        WindowEnumerator.refreshAppAsync(pid: app.processIdentifier)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        unwatch(pid)
        WindowEnumerator.remove(pid: pid)
    }

    private func isTrackable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != myPID
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        unwatch(pid)

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<WindowCacheObserver>.fromOpaque(refcon).takeUnretainedValue()
            watcher.handle(element: element, notification: notification as String)
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Some apps reject the notification; that's fine — launch/space refresh
        // and the snapshot CG diff still cover those.
        _ = AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = (obs, axApp)
    }

    private func unwatch(_ pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(entry.obs, entry.app, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(entry.obs),
            .commonModes
        )
    }

    private func handle(element: AXUIElement, notification: String) {
        guard notification == kAXWindowCreatedNotification as String else { return }
        // Targeted probe for the owning app; fall back to a coalesced full
        // sweep only when we can't resolve a pid from the element.
        if let pid = pid(ofAXElement: element) {
            WindowEnumerator.refreshAppAsync(pid: pid)
        } else if let wid = PrivateAX.windowID(of: element),
                  let pid = pid(ofWindowID: wid) {
            WindowEnumerator.refreshAppAsync(pid: pid)
        } else {
            WindowEnumerator.refreshAsync()
        }
    }

    private func pid(ofWindowID wid: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        return pid
    }

    private func pid(ofAXElement element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }
}
