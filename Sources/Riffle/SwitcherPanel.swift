import AppKit

/// The floating switcher UI: a vertical list of rows, each showing
/// the app icon and window title only (no window previews).
final class SwitcherPanelController {
    private let panel: NSPanel
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    // Sits over the blur; its alpha turns the panel from glassy to solid.
    private let backgroundOverlay = NSView()
    private let topHint = OverflowHint()
    private let bottomHint = OverflowHint()
    private var rows: [SwitcherRow] = []

    /// Fires when the cursor moves onto a row, with that row's index.
    var onHover: ((Int) -> Void)?
    /// Where the cursor sat when the panel appeared. Cleared once it moves.
    private var mouseAnchor: NSPoint?
    private var edgeScrollTimer: Timer?

    /// How many rows the panel shows at once. Any beyond this are scrolled to,
    /// not dropped. Also the count at which sizing reaches its compact end.
    private static let maxVisibleRows = 18
    /// How far the cursor must travel before hover counts, in points.
    private static let hoverSlop: CGFloat = 2
    /// Cursor distance from the panel's top/bottom edge that scrolls the list.
    private static let edgeZone: CGFloat = 44
    /// Points per tick at the very edge; tapers to zero at the zone's inner rim.
    private static let maxEdgeSpeed: CGFloat = 16
    /// Keeps the panel clear of the screen edges when the list is long.
    private static let screenMargin: CGFloat = 40

    /// Per-row sizing that grows as the list shrinks, so a couple of windows
    /// fill a comfortable panel instead of a cramped strip. Interpolated
    /// between a roomy layout (one row) and the compact layout (a full list).
    fileprivate struct Metrics {
        let rowWidth: CGFloat
        let rowHeight: CGFloat
        let iconSize: CGFloat
        let titleFontSize: CGFloat
        let cornerRadius: CGFloat

        static let roomy = Metrics(rowWidth: 560, rowHeight: 64, iconSize: 44, titleFontSize: 19, cornerRadius: 12)
        static let compact = Metrics(rowWidth: 460, rowHeight: 34, iconSize: 22, titleFontSize: 13, cornerRadius: 8)

        // `scale` shifts the whole dynamic range up or down (the user setting);
        // corner radius is left unscaled so rounding stays consistent.
        static func forCount(_ count: Int, scale: CGFloat) -> Metrics {
            let span = max(1, maxVisibleRows - 1)
            let t = min(max(CGFloat(count - 1) / CGFloat(span), 0), 1)
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * t) * scale }
            return Metrics(
                rowWidth: lerp(roomy.rowWidth, compact.rowWidth),
                rowHeight: lerp(roomy.rowHeight, compact.rowHeight),
                iconSize: lerp(roomy.iconSize, compact.iconSize),
                titleFontSize: lerp(roomy.titleFontSize, compact.titleFontSize),
                cornerRadius: roomy.cornerRadius + (compact.cornerRadius - roomy.cornerRadius) * t
            )
        }
    }

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        // A layer corner radius rounds what this view *draws*, but `behindWindow`
        // blur is composited by the window server, which knows nothing about our
        // layers — so the blur itself stayed a hard-edged rectangle and its
        // square corners showed through behind the rounded ones. `maskImage` is
        // the shape the window server actually honours. The layer radius stays
        // for the subviews it does clip.
        effect.maskImage = Self.roundedMask(radius: 14)
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        backgroundOverlay.wantsLayer = true
        backgroundOverlay.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(backgroundOverlay)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The list can outgrow the screen, so it rides in a scroll view. The
        // clip view is flipped to keep row 0 pinned to the top as it scrolls.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        effect.addSubview(scrollView)
        effect.addSubview(topHint)
        effect.addSubview(bottomHint)

        NSLayoutConstraint.activate([
            backgroundOverlay.topAnchor.constraint(equalTo: effect.topAnchor),
            backgroundOverlay.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            backgroundOverlay.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            backgroundOverlay.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: effect.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            // No bottom pin: the document's height is the list's full height,
            // which is what gives the scroll view something to scroll.
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            topHint.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            topHint.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            bottomHint.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            bottomHint.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    /// A rounded-rect mask that stretches to any panel size: the corners are
    /// drawn once and the flat middle is repeated, so it never distorts.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(windows: [WindowInfo], selected: Int, on screen: NSScreen?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let scale = CGFloat(Config.shared.listScale)
        let visibleCount = min(windows.count, Self.maxVisibleRows)
        let metrics = Metrics.forCount(visibleCount, scale: scale)
        mouseAnchor = NSEvent.mouseLocation
        rows = windows.enumerated().map { index, window in
            let row = SwitcherRow(window: window, metrics: metrics)
            row.onHover = { [weak self] in self?.hoverSelect(index) }
            return row
        }
        rows.forEach { stack.addArrangedSubview($0) }
        // Resolve every layer colour against the panel's *live* appearance.
        // Layer colours are frozen `CGColor`s, so without this they'd bake in
        // whatever theme was current at launch and never follow a light/dark
        // switch — the panel would keep its old theme until the app relaunched.
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.backgroundOverlay.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(CGFloat(Config.shared.backgroundOpacity)).cgColor
            self.applySelection(selected)
        }

        stack.layoutSubtreeIfNeeded()
        let content = stack.fittingSize
        let target = screen ?? NSScreen.main
        let screenFrame = target?.visibleFrame ?? .zero
        // Every window gets a row; the panel just shows `maxVisibleRows` of them
        // and scrolls the rest, so nothing selectable is ever unreachable.
        // The screen is only a backstop for a tall list at a large list scale.
        let listHeight = CGFloat(visibleCount) * metrics.rowHeight
            + CGFloat(max(0, visibleCount - 1)) * stack.spacing
            + stack.edgeInsets.top + stack.edgeInsets.bottom
        let maxHeight = min(listHeight, max(metrics.rowHeight, screenFrame.height - Self.screenMargin * 2))
        let size = NSSize(width: content.width, height: min(content.height, maxHeight))
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        // Scrolling needs the final frame, so this waits until after setFrame.
        panel.contentView?.layoutSubtreeIfNeeded()
        // The clip view keeps its offset between sessions, so a list left
        // scrolled down would reopen mid-list. Always start at the top, then
        // let the initial selection pull the list down if it needs to.
        scroll(toY: 0)
        scrollToRow(selected)
        updateOverflowHints()
        startEdgeScroll()
    }

    /// `scroll` is false for mouse-driven selection: the pointer is already on
    /// the row, and scrolling under it would fight the cursor.
    func select(_ index: Int, scroll: Bool = true) {
        // Same reason as in `show`: the selected/resting fills are frozen
        // `CGColor`s, so resolve them against the live theme, not launch's.
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.applySelection(index)
        }
        guard scroll else { return }
        scrollToRow(index)
        // The keyboard just moved the selection, so hand control back to it: a
        // cursor resting in the edge zone would otherwise keep scrolling and
        // drag the selection straight back off the row you just tabbed to.
        mouseAnchor = NSEvent.mouseLocation
    }

    /// Sets each row's selected state. Call inside a `performAsCurrentDrawing`
    /// block so the frozen fill colours resolve against the live theme.
    private func applySelection(_ index: Int) {
        for (i, row) in rows.enumerated() {
            row.isSelected = (i == index)
        }
    }

    private func scrollToRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        // Wrapping past either end should land on the true end of the list.
        // Scrolling just far enough to expose the row would leave the list
        // mid-way, so the wrap reads as a stutter rather than a jump.
        if index == 0 {
            scroll(toY: 0)
        } else if index == rows.count - 1 {
            scroll(toY: max(0, document.frame.height - scrollView.contentView.bounds.height))
        } else {
            // A little slop above and below keeps the neighbouring row peeking
            // in, so it stays obvious that the list continues.
            let row = rows[index]
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -row.bounds.height))
        }
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        guard y != clip.bounds.origin.y else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The panel is centred on screen, so it often opens right under the cursor.
    /// Ignore hovers until the mouse actually moves, or a resting cursor would
    /// hijack the keyboard's selection the instant the list appeared.
    private func hoverSelect(_ index: Int) {
        guard mouseHasMoved() else { return }
        startEdgeScroll()
        onHover?(index)
    }

    private func mouseHasMoved() -> Bool {
        guard let anchor = mouseAnchor else { return true }
        let now = NSEvent.mouseLocation
        guard abs(now.x - anchor.x) > Self.hoverSlop
                || abs(now.y - anchor.y) > Self.hoverSlop else { return false }
        mouseAnchor = nil
        return true
    }

    // MARK: - Overflow

    private var isScrollable: Bool {
        document.frame.height > scrollView.contentView.bounds.height + 0.5
    }

    @objc private func scrolled() {
        updateOverflowHints()
    }

    /// Counts the rows past each edge and labels them, so a clipped list says
    /// how much more there is instead of just ending.
    ///
    /// A row counts the moment *any* of it is clipped, not once it's fully
    /// gone: a half-visible row is still a window you can't read, and the panel
    /// is sized in whole rows, so the leftover is usually a partial row that a
    /// fully-outside test would score as zero and hide the badge entirely.
    private func updateOverflowHints() {
        let visible = scrollView.documentVisibleRect
        var above = 0
        var below = 0
        for row in rows {
            let frame = row.convert(row.bounds, to: document)
            if frame.minY < visible.minY - 0.5 {
                above += 1
            } else if frame.maxY > visible.maxY + 0.5 {
                below += 1
            }
        }
        topHint.update(count: above, symbol: "chevron.up")
        bottomHint.update(count: below, symbol: "chevron.down")
    }

    // MARK: - Edge scrolling

    /// Resting the cursor near the top or bottom edge scrolls the list, so the
    /// clipped rows are reachable by mouse as well as by tab/arrows.
    /// Idempotent, and cheap to call from every hover: the timer only exists
    /// while the pointer is actually in the panel, and stops itself the moment
    /// it leaves. A hover brings it back — which is the only way back in.
    private func startEdgeScroll() {
        guard edgeScrollTimer == nil, isScrollable else { return }
        edgeScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepEdgeScroll()
        }
    }

    private func stopEdgeScroll() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
    }

    private func stepEdgeScroll() {
        // Bail out on the pointer being away *before* the moved-yet check:
        // that check returns early while the cursor is still resting, which
        // would otherwise keep the timer alive off-panel for no reason.
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse) else {
            stopEdgeScroll()
            return
        }
        guard mouseHasMoved() else { return }

        var speed: CGFloat = 0
        if mouse.y < frame.minY + Self.edgeZone {
            let depth = (frame.minY + Self.edgeZone - mouse.y) / Self.edgeZone
            speed = min(depth, 1) * Self.maxEdgeSpeed
        } else if mouse.y > frame.maxY - Self.edgeZone {
            let depth = (mouse.y - (frame.maxY - Self.edgeZone)) / Self.edgeZone
            speed = -min(depth, 1) * Self.maxEdgeSpeed
        }
        guard speed != 0 else { return }

        let clip = scrollView.contentView
        let limit = max(0, document.frame.height - clip.bounds.height)
        scroll(toY: min(max(clip.bounds.origin.y + speed, 0), limit))
    }

    func hide() {
        mouseAnchor = nil
        stopEdgeScroll()
        panel.orderOut(nil)
    }
}

/// Flipped so the list is laid out and scrolled from the top down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The "N more" pill shown at a clipped edge of the list.
private final class OverflowHint: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.9).cgColor

        icon.contentTintColor = .black
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 14),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 7),
            icon.heightAnchor.constraint(equalToConstant: 7),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(count: Int, symbol: String) {
        isHidden = count == 0
        guard count > 0 else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        label.stringValue = "\(count) more"
    }
}

private final class SwitcherRow: NSView {
    // Same neutral hue for both states: a light wash for the resting row and a
    // darker fill for the selected one (replacing the old accent-blue).
    private static let restingBackground = NSColor.systemGray.withAlphaComponent(0.22)
    private static let selectedBackground = NSColor.systemGray.withAlphaComponent(0.85)

    /// Called on every cursor move over this row.
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?

    var isSelected: Bool = false {
        didSet {
            layer?.backgroundColor = isSelected
                ? Self.selectedBackground.cgColor
                : Self.restingBackground.cgColor
            titleLabel.textColor = isSelected ? .black : .labelColor
        }
    }

    private let titleLabel: NSTextField

    init(window: WindowInfo, metrics: SwitcherPanelController.Metrics) {
        titleLabel = NSTextField(labelWithString: window.title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = metrics.cornerRadius

        let iconView = NSImageView()
        iconView.image = window.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: metrics.titleFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: metrics.rowWidth),
            heightAnchor.constraint(equalToConstant: metrics.rowHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: metrics.iconSize),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // `.activeAlways` matters: Riffle never activates, so an ordinary tracking
    // area (or window mouseMoved events) would stay silent while another app
    // holds focus. `.mouseMoved` covers the case where the panel opens under
    // the cursor — no boundary is crossed, so mouseEntered never fires.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
}
