import AppKit

/// A click-through accent-colored frame drawn around the window gaze has
/// picked. In the hold-look-release flow it is the whole UI: the user sees
/// what releasing will focus and can correct by looking slightly elsewhere,
/// which is what makes a coarse tracker usable.
final class GazeHighlightPanel {
    private let panel: NSPanel
    private let border = BorderView()
    private var fadeToken = 0

    /// Stroke sits just outside the window edge so it never covers content.
    private static let inset: CGFloat = -3

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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = border
    }

    /// `frame` is in CG (top-left) coordinates, as `WindowInfo.frame` is.
    func show(around frame: CGRect) {
        fadeToken &+= 1
        let target = ScreenCoords.appKitRect(fromCG: frame).insetBy(dx: Self.inset, dy: Self.inset)
        panel.alphaValue = 1
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        fadeToken &+= 1
        panel.orderOut(nil)
    }

    /// Brief confirmation that a dwell switch happened, and why.
    func flash(around frame: CGRect) {
        show(around: frame)
        fadeToken &+= 1
        let token = fadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard token == fadeToken else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: { [self] in
                guard token == fadeToken else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        }
    }

    private final class BorderView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.borderWidth = 4
            layer?.cornerRadius = 12
            layer?.masksToBounds = true
            updateColor()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func updateColor() {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
