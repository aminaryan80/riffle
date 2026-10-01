import AppKit
import AVFoundation

/// The Settings window: edit/add/remove shortcuts (with live key recording),
/// choose what each shortcut shows, tune gaze focus, and manage the
/// excluded-apps list.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var window: NSWindow?

    private let bindingsStack = NSStackView()
    private let excludedStack = NSStackView()
    private let addAppButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private let gazeEnabledBox = NSButton(checkboxWithTitle: "Enable gaze tracking", target: nil, action: nil)
    private let gazeStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let cameraPopup = NSPopUpButton()
    private let calibrateButton = NSButton(title: "Calibrate…", target: nil, action: nil)
    private let cameraPrivacyButton = NSButton(title: "Open Camera Privacy Settings…", target: nil, action: nil)
    private let dwellBox = NSButton(checkboxWithTitle: "Switch focus automatically when I look at a window",
                                    target: nil, action: nil)
    private let dwellSlider = NSSlider()
    private let dwellValueLabel = NSTextField(labelWithString: "")
    private var gazeStatusTimer: Timer?

    private var comboButtons: [NSButton] = []
    private var recordingIndex: Int?

    private static let rowWidth: CGFloat = 540

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Tracking state changes on its own (face in/out of view, camera
        // coming up); a slow poll keeps the status line honest while open.
        gazeStatusTimer?.invalidate()
        gazeStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateGazeStatus()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelRecording()
        gazeStatusTimer?.invalidate()
        gazeStatusTimer = nil
    }

    // MARK: - Layout

    private func buildWindow() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        content.addArrangedSubview(header("Shortcuts"))
        content.addArrangedSubview(caption(
            "Click a shortcut to change it, then press the new key combination. "
            + "Shortcuts need ⌘, ⌥ or ⌃. Holding ⇧ cycles backwards. Esc cancels recording."))
        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .leading
        bindingsStack.spacing = 6
        content.addArrangedSubview(bindingsStack)
        let addShortcut = NSButton(title: "Add Shortcut", target: self, action: #selector(addShortcutTapped))
        addShortcut.bezelStyle = .rounded
        content.addArrangedSubview(addShortcut)

        content.addArrangedSubview(spacer(12))
        content.addArrangedSubview(header("Appearance"))
        content.addArrangedSubview(caption(
            "List size scales the whole switcher; it still grows for shorter lists. "
            + "Background goes from glassy (translucent) to solid."))
        content.addArrangedSubview(sliderRow(
            title: "List size",
            range: Config.listScaleRange,
            value: Config.shared.listScale,
            leading: "Small", trailing: "Large",
            action: #selector(listScaleChanged(_:))))
        content.addArrangedSubview(sliderRow(
            title: "Background",
            range: Config.backgroundOpacityRange,
            value: Config.shared.backgroundOpacity,
            leading: "Glassy", trailing: "Solid",
            action: #selector(backgroundOpacityChanged(_:))))

        content.addArrangedSubview(spacer(12))
        content.addArrangedSubview(header("Gaze Focus"))
        content.addArrangedSubview(caption(
            "Uses your camera to tell which window you're looking at. Video is processed on this Mac "
            + "and never stored or sent anywhere. Expect it to tell windows apart, not to point precisely."))
        buildGazeControls(into: content)

        content.addArrangedSubview(spacer(12))
        content.addArrangedSubview(header("Excluded Apps"))
        content.addArrangedSubview(caption("Windows of these apps never appear in any list."))
        excludedStack.orientation = .vertical
        excludedStack.alignment = .leading
        excludedStack.spacing = 6
        content.addArrangedSubview(excludedStack)
        content.addArrangedSubview(addAppButton)
        addAppButton.target = self
        addAppButton.action = #selector(addAppSelected)

        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.rowWidth + 32),
        ])

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Riffle Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = container
        win.center()
        window = win
    }

    private func reload() {
        cancelRecording()
        rebuildBindingRows()
        reloadGazeControls()
        rebuildExcludedRows()
        resizeToFit()
    }

    private func resizeToFit() {
        guard let window, let container = window.contentView,
              let content = container.subviews.first as? NSStackView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        window.setContentSize(size)
    }

    // MARK: - Shortcut rows

    private func rebuildBindingRows() {
        bindingsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        comboButtons = []
        for (index, binding) in Config.shared.fileBindings.enumerated() {
            let combo = NSButton(title: Config.displayString(for: binding), target: self, action: #selector(recordTapped(_:)))
            combo.bezelStyle = .rounded
            combo.tag = index
            combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            comboButtons.append(combo)

            let scope = NSPopUpButton()
            for s in Scope.allCases { scope.addItem(withTitle: s.label) }
            if let selected = Scope.allCases.firstIndex(of: binding.scope) {
                scope.selectItem(at: selected)
            }
            scope.tag = index
            scope.target = self
            scope.action = #selector(scopeChanged(_:))

            let remove = NSButton(title: "Remove", target: self, action: #selector(removeBindingTapped(_:)))
            remove.bezelStyle = .rounded
            remove.tag = index

            let row = NSStackView(views: [combo, scope, NSView(), remove])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
            bindingsStack.addArrangedSubview(row)
        }
    }

    @objc private func recordTapped(_ sender: NSButton) {
        cancelRecording()
        recordingIndex = sender.tag
        sender.title = "Type shortcut…"
        appDelegate?.recordingHandler = { [weak self] keyCode, flags in
            self?.captured(keyCode: keyCode, flags: flags)
        }
    }

    private func captured(keyCode: Int64, flags: CGEventFlags) {
        guard let index = recordingIndex else { return }
        if keyCode == 53 { // escape cancels
            reload()
            return
        }
        guard let name = Config.keyNames[keyCode] else {
            NSSound.beep()
            return
        }
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskAlternate) { mods.append("option") }
        if flags.contains(.maskControl) { mods.append("ctrl") }
        guard !mods.isEmpty else { // shift alone can't hold a switcher session
            NSSound.beep()
            return
        }
        if flags.contains(.maskShift) { mods.append("shift") }

        guard Config.shared.fileBindings.indices.contains(index) else { return }
        var binding = Config.shared.fileBindings[index]
        binding.key = name
        binding.modifiers = mods
        Config.shared.updateBinding(at: index, binding)
        reload()
    }

    private func cancelRecording() {
        appDelegate?.recordingHandler = nil
        if let index = recordingIndex, comboButtons.indices.contains(index),
           Config.shared.fileBindings.indices.contains(index) {
            comboButtons[index].title = Config.displayString(for: Config.shared.fileBindings[index])
        }
        recordingIndex = nil
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard Config.shared.fileBindings.indices.contains(index),
              Scope.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        var binding = Config.shared.fileBindings[index]
        binding.scope = Scope.allCases[sender.indexOfSelectedItem]
        Config.shared.updateBinding(at: index, binding)
    }

    @objc private func removeBindingTapped(_ sender: NSButton) {
        Config.shared.removeBinding(at: sender.tag)
        reload()
    }

    @objc private func addShortcutTapped() {
        Config.shared.addBinding(KeyBinding(key: "tab", modifiers: ["cmd"], scope: .activeScreen))
        reload()
        // Immediately record the new row so the placeholder combo isn't kept by accident.
        if let last = comboButtons.last { recordTapped(last) }
    }

    // MARK: - Excluded apps

    private func rebuildExcludedRows() {
        excludedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, identifier) in Config.shared.excludedApps.enumerated() {
            let (name, icon) = Self.appInfo(for: identifier)
            let iconView = NSImageView()
            iconView.image = icon
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

            let label = NSTextField(labelWithString: name)
            label.lineBreakMode = .byTruncatingTail

            let remove = NSButton(title: "Remove", target: self, action: #selector(removeAppTapped(_:)))
            remove.bezelStyle = .rounded
            remove.tag = index

            let row = NSStackView(views: [iconView, label, NSView(), remove])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
            excludedStack.addArrangedSubview(row)
        }
        if Config.shared.excludedApps.isEmpty {
            excludedStack.addArrangedSubview(caption("No apps excluded."))
        }
        rebuildAddAppMenu()
    }

    private func rebuildAddAppMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Add App…", action: nil, keyEquivalent: "")) // pull-down title
        let excluded = Set(Config.shared.excludedApps)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            let identifier = app.bundleIdentifier ?? app.localizedName ?? ""
            guard !identifier.isEmpty, !excluded.contains(identifier) else { continue }
            let item = NSMenuItem(title: app.localizedName ?? identifier, action: #selector(runningAppPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            if let icon = app.icon {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                item.image = small
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other (choose an app)…", action: #selector(pickAppFromDisk), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        addAppButton.menu = menu
    }

    @objc private func addAppSelected() {
        // Selection handled per menu item; nothing to do here.
    }

    @objc private func runningAppPicked(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        Config.shared.addExcludedApp(identifier)
        reload()
    }

    @objc private func pickAppFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedFileTypes = ["app"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let identifier = Bundle(url: url)?.bundleIdentifier
            ?? url.deletingPathExtension().lastPathComponent
        Config.shared.addExcludedApp(identifier)
        reload()
    }

    @objc private func removeAppTapped(_ sender: NSButton) {
        Config.shared.removeExcludedApp(at: sender.tag)
        reload()
    }

    // MARK: - Appearance

    @objc private func listScaleChanged(_ sender: NSSlider) {
        Config.shared.setListScale(sender.doubleValue)
    }

    @objc private func backgroundOpacityChanged(_ sender: NSSlider) {
        Config.shared.setBackgroundOpacity(sender.doubleValue)
    }

    // MARK: - Gaze focus

    private func buildGazeControls(into content: NSStackView) {
        gazeEnabledBox.target = self
        gazeEnabledBox.action = #selector(gazeEnabledToggled)
        content.addArrangedSubview(gazeEnabledBox)

        gazeStatusLabel.font = .systemFont(ofSize: 11)
        gazeStatusLabel.textColor = .secondaryLabelColor
        gazeStatusLabel.preferredMaxLayoutWidth = Self.rowWidth
        content.addArrangedSubview(gazeStatusLabel)

        let cameraLabel = NSTextField(labelWithString: "Camera")
        cameraLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraPicked)
        let cameraRow = NSStackView(views: [cameraLabel, cameraPopup, NSView()])
        cameraRow.orientation = .horizontal
        cameraRow.spacing = 8
        cameraRow.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        content.addArrangedSubview(cameraRow)

        calibrateButton.bezelStyle = .rounded
        calibrateButton.target = self
        calibrateButton.action = #selector(calibrateTapped)
        cameraPrivacyButton.bezelStyle = .rounded
        cameraPrivacyButton.target = self
        cameraPrivacyButton.action = #selector(openCameraPrivacy)
        let buttonRow = NSStackView(views: [calibrateButton, cameraPrivacyButton, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        content.addArrangedSubview(buttonRow)

        dwellBox.target = self
        dwellBox.action = #selector(dwellToggled)
        content.addArrangedSubview(dwellBox)

        let dwellLabel = NSTextField(labelWithString: "Look for")
        dwellLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        dwellSlider.minValue = GazeSettings.dwellRange.lowerBound
        dwellSlider.maxValue = GazeSettings.dwellRange.upperBound
        dwellSlider.isContinuous = true
        dwellSlider.target = self
        dwellSlider.action = #selector(dwellSecondsChanged(_:))
        dwellSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        dwellValueLabel.font = .systemFont(ofSize: 11)
        dwellValueLabel.textColor = .secondaryLabelColor
        dwellValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let dwellRow = NSStackView(views: [dwellLabel, endcapLabel("Quick"), dwellSlider, endcapLabel("Patient"), dwellValueLabel])
        dwellRow.orientation = .horizontal
        dwellRow.spacing = 8
        dwellRow.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        content.addArrangedSubview(dwellRow)

        content.addArrangedSubview(caption(
            "Automatic switching waits until you've stopped typing and mousing. For on-demand switching, "
            + "set a shortcut above to “\(Scope.gaze.label)”: hold it, look at a window, release."))
    }

    private func reloadGazeControls() {
        let settings = Config.shared.gaze
        dwellSlider.doubleValue = settings.dwellSeconds
        dwellValueLabel.stringValue = String(format: "%.1f s", settings.dwellSeconds)
        rebuildCameraMenu()
        updateGazeStatus()
    }

    /// Checkbox and enabled states only — never slider values, which the
    /// user may be dragging when the status timer fires.
    private func syncGazeControlStates() {
        let settings = Config.shared.gaze
        gazeEnabledBox.state = settings.enabled ? .on : .off
        dwellBox.state = settings.dwellEnabled ? .on : .off
        dwellBox.isEnabled = settings.enabled
        dwellSlider.isEnabled = settings.enabled && settings.dwellEnabled
        cameraPopup.isEnabled = settings.enabled
        let status = CameraCapture.authorizationStatus
        calibrateButton.isEnabled = status != .denied && status != .restricted
    }

    private func rebuildCameraMenu() {
        cameraPopup.removeAllItems()
        cameraPopup.addItem(withTitle: "System default")
        cameraPopup.lastItem?.representedObject = nil
        let selectedID = Config.shared.gaze.cameraID
        var selectedIndex = 0
        for device in CameraCapture.availableCameras() {
            cameraPopup.addItem(withTitle: device.localizedName)
            cameraPopup.lastItem?.representedObject = device.uniqueID
            if device.uniqueID == selectedID { selectedIndex = cameraPopup.numberOfItems - 1 }
        }
        cameraPopup.selectItem(at: selectedIndex)
    }

    private func updateGazeStatus() {
        syncGazeControlStates()
        let camera: String
        switch CameraCapture.authorizationStatus {
        case .authorized: camera = "allowed"
        case .notDetermined: camera = "not asked yet"
        case .denied: camera = "denied"
        case .restricted: camera = "restricted"
        @unknown default: camera = "unknown"
        }
        let denied = CameraCapture.authorizationStatus == .denied || CameraCapture.authorizationStatus == .restricted
        cameraPrivacyButton.isHidden = !denied

        let calibration: String
        if let model = GazeCalibrationStore.shared.model() {
            calibration = "ready (avg. error \(Int(model.meanErrorPoints.rounded())) pt)"
        } else {
            calibration = "needed for this monitor layout"
        }

        let tracking: String
        switch GazeFocusController.shared.visionSource.state {
        case .off: tracking = "off"
        case .starting: tracking = "starting camera…"
        case .noCamera: tracking = "no camera"
        case .noFace: tracking = "no face in view"
        case .tracking: tracking = "face detected"
        }
        gazeStatusLabel.stringValue = "Camera: \(camera)  ·  Calibration: \(calibration)  ·  Tracking: \(tracking)"
    }

    @objc private func gazeEnabledToggled() {
        var settings = Config.shared.gaze
        guard gazeEnabledBox.state == .on else {
            settings.enabled = false
            Config.shared.setGaze(settings)
            reloadGazeControls()
            return
        }
        GazeFocusController.shared.ensureCameraAccess { [weak self] granted in
            guard let self else { return }
            var settings = Config.shared.gaze
            settings.enabled = granted
            Config.shared.setGaze(settings)
            // Without a shortcut or dwell, enabling does nothing visible. Hand
            // the user a shortcut (it shows up in the list above) unless that
            // combination is already taken.
            let def = GazeSettings.defaultGazeBinding
            if granted, !Config.shared.hasGazeBinding, !settings.dwellEnabled,
               !Config.shared.hasBinding(key: def.key, modifiers: def.modifiers) {
                Config.shared.addBinding(def)
                rebuildBindingRows()
                resizeToFit()
            }
            reloadGazeControls()
            if !granted { NSSound.beep() }
        }
    }

    @objc private func cameraPicked() {
        var settings = Config.shared.gaze
        settings.cameraID = cameraPopup.selectedItem?.representedObject as? String
        Config.shared.setGaze(settings)
    }

    @objc private func calibrateTapped() {
        GazeFocusController.shared.calibrate()
    }

    @objc private func openCameraPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func dwellToggled() {
        var settings = Config.shared.gaze
        settings.dwellEnabled = dwellBox.state == .on
        Config.shared.setGaze(settings)
        reloadGazeControls()
    }

    @objc private func dwellSecondsChanged(_ sender: NSSlider) {
        var settings = Config.shared.gaze
        settings.dwellSeconds = sender.doubleValue
        Config.shared.setGaze(settings)
        dwellValueLabel.stringValue = String(format: "%.1f s", Config.shared.gaze.dwellSeconds)
    }

    private static func appInfo(for identifier: String) -> (String, NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (identifier, NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil))
    }

    // MARK: - Small view helpers

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 15)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.rowWidth
        return label
    }

    private func sliderRow(
        title: String,
        range: ClosedRange<Double>,
        value: Double,
        leading: String,
        trailing: String,
        action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let leadingLabel = endcapLabel(leading)
        let trailingLabel = endcapLabel(trailing)

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let row = NSStackView(views: [label, leadingLabel, slider, trailingLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        return row
    }

    private func endcapLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
