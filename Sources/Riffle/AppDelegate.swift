import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = SwitcherController()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var secureInputTimer: Timer?
    private var secureInputItem: NSMenuItem?
    private lazy var settings = SettingsWindowController(appDelegate: self)

    /// While non-nil, the tap consumes every key press and feeds it here
    /// instead of the switcher (the Settings window is recording a shortcut).
    var recordingHandler: ((Int64, CGEventFlags) -> Void)?

    private static let escapeKeyCode: Int64 = 53
    private static let arrowsBackward: Set<Int64> = [126, 123] // up, left
    private static let arrowsForward: Set<Int64> = [125, 124]  // down, right

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.shared.load()
        setupStatusItem()
        startSecureInputMonitor()

        if AXIsProcessTrusted() {
            startEventTap()
        } else {
            promptForAccessibility()
        }

        // Delay the silent update check so it never competes with the first-run
        // Accessibility prompt for the user's attention.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - Secure Keyboard Entry detection
    // When any app enables secure input (e.g. Terminal's "Secure Keyboard
    // Entry"), macOS withholds keystrokes from event taps, so our hotkeys
    // silently stop working while that app is focused. We can't bypass it —
    // but we can tell the user what's going on.

    private func startSecureInputMonitor() {
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateSecureInputWarning()
        }
        updateSecureInputWarning()
    }

    private func updateSecureInputWarning() {
        let blocked = IsSecureEventInputEnabled()
        secureInputItem?.isHidden = !blocked
        statusItem?.button?.image = NSImage(
            systemSymbolName: blocked ? "exclamationmark.triangle.fill" : "macwindow.on.rectangle",
            accessibilityDescription: "Riffle"
        )
        statusItem?.button?.toolTip = blocked
            ? "Hotkeys are blocked: an app has Secure Keyboard Entry enabled"
            : nil
    }

    // MARK: - Accessibility permission

    private func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Poll until the user grants access, then start the tap.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startEventTap()
        }
    }

    // MARK: - Event tap

    private func startEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            return delegate.handle(type: type, event: event)
        }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else {
            NSLog("Riffle: failed to create event tap — is Accessibility access granted?")
            promptForAccessibility()
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        // Cap every AX call the app makes (including remote-token elements) so a
        // hung app's server can't stall the switcher for seconds. Per-element
        // timeouts still apply where set; this is the process-wide default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        // Accessibility is granted at this point, so focus tracking and
        // event-driven cache upkeep work too.
        FocusHistory.shared.start()
        WindowCacheObserver.shared.start()
        registerWorkspaceObservers()
        WindowEnumerator.refreshAsync()
        NSLog("Riffle: event tap active")
    }

    // Keep the window cache fresh from workspace events. Launch/activate/space
    // changes ask for a coalesced full sweep; terminate also prunes the pid
    // immediately so a quit never lingers for one trigger.
    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            center.addObserver(self, selector: #selector(refreshWindowCache), name: name, object: nil)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            WindowEnumerator.remove(pid: app.processIdentifier)
        }
        WindowEnumerator.refreshAsync()
    }

    @objc private func refreshWindowCache() {
        WindowEnumerator.refreshAsync()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            if let handler = recordingHandler {
                DispatchQueue.main.async { handler(keyCode, flags) }
                return nil // consume — recorded, not typed
            }
            if switcher.isActive && keyCode == Self.escapeKeyCode {
                DispatchQueue.main.async { self.switcher.cancel() }
                return nil // consume
            }
            if switcher.isActive,
               Self.arrowsBackward.contains(keyCode) || Self.arrowsForward.contains(keyCode) {
                let backwards = Self.arrowsBackward.contains(keyCode)
                DispatchQueue.main.async { self.switcher.step(backwards: backwards) }
                return nil // consume
            }
            if let binding = Config.shared.binding(keyCode: keyCode, flags: flags) {
                let backwards = flags.contains(.maskShift)
                // Do the real work outside the tap callback so the tap never
                // stalls (slow AX calls would get the tap disabled by timeout).
                DispatchQueue.main.async {
                    self.switcher.handleTrigger(binding: binding, backwards: backwards)
                }
                return nil // consume — keeps the native cmd+tab switcher out of the way
            }
        } else if type == .flagsChanged {
            // Check state inside the queued block, not here: on a very fast
            // tap-and-release this event can arrive before the queued trigger
            // has activated the switcher, and the FIFO main queue fixes the order.
            let flags = event.flags
            DispatchQueue.main.async {
                if self.switcher.isActive && !self.switcher.holdStillHeld(flags: flags) {
                    self.switcher.commit()
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Riffle"
        )

        let menu = NSMenu()
        let warning = NSMenuItem(
            title: "⚠️ Hotkeys blocked by Secure Keyboard Entry",
            action: nil,
            keyEquivalent: ""
        )
        warning.toolTip = "Some app (usually a terminal) has Secure Keyboard Entry on, "
            + "which hides keystrokes from Riffle while it's focused. "
            + "In Terminal: menu bar > Terminal > untick Secure Keyboard Entry."
        warning.isEnabled = false
        warning.isHidden = true
        secureInputItem = warning
        menu.addItem(warning)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Riffle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func checkForUpdates() {
        Updater.checkForUpdates()
    }
}
