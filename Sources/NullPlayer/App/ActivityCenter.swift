import AppKit

/// Background-work progress (a rip, an EQ Cast render), shown as a stack of rows in a small
/// borderless "NullPlayer" notification panel at the top-right of the screen holding the main window.
///
/// It lives off the main window because `.wal`, `.wmz` and Audion players are arbitrary shapes —
/// a bar inside the player lands on transparent pixels or skin chrome. One row per `id`, so two
/// jobs running at once never overwrite each other; newest at the bottom. The header's chevron
/// collapses the rows to a one-line summary, remembered across launches.
@MainActor
final class ActivityCenter: NSObject {
    static let shared = ActivityCenter()

    private static let collapsedKey = "activityCenterCollapsed"
    private let width: CGFloat = 300
    private let screenInset: CGFloat = 16
    private var labels: [String: NSTextField] = [:]
    private let rows = NSStackView()
    private let title = NSTextField(labelWithString: "NullPlayer")
    private let toggle = NSButton()
    private lazy var panel = makePanel()

    private var collapsed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.collapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.collapsedKey) }
    }

    private override init() {}

    /// Show a spinner row for `id`, or update its message if it is already showing.
    func show(id: String, message: String) {
        guard !AudioEngine.isHeadless else { return }
        if let label = labels[id] {
            label.stringValue = message
            return
        }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        rows.addArrangedSubview(row)
        labels[id] = label
        place()
    }

    func hide(id: String) {
        guard let label = labels.removeValue(forKey: id) else { return }
        label.superview?.removeFromSuperview()
        if labels.isEmpty { panel.orderOut(nil) } else { place() }
    }

    @objc private func toggleCollapsed() {
        collapsed.toggle()
        place()
    }

    /// Apply the collapsed state, size the panel to its content and park it in the top-right of
    /// the main window's screen.
    private func place() {
        rows.isHidden = collapsed
        title.stringValue = collapsed
            ? "NullPlayer — \(labels.count) running"
            : "NullPlayer"
        toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up",
                               accessibilityDescription: collapsed ? "Show" : "Hide")

        let height = panel.contentView?.fittingSize.height ?? 40
        let size = NSSize(width: width, height: height)
        let anchor = WindowManager.shared.mainWindowController?.window ?? NSApp.keyWindow
        let bounds = anchor?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: bounds.maxX - screenInset - size.width,
                             y: bounds.maxY - screenInset - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        // Rounded via the mask, not `layer.cornerRadius` — see `SkinLoadingOverlay.roundedMask`.
        container.maskImage = SkinLoadingOverlay.roundedMask(cornerRadius: 10)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.alphaValue = 0.5
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        title.font = .boldSystemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggle.isBordered = false
        toggle.imagePosition = .imageOnly
        toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleCollapsed)

        let header = NSStackView(views: [title, NSView(), toggle])
        header.spacing = 4

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6

        let text = NSStackView(views: [header, rows])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        header.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let outer = NSStackView(views: [icon, text])
        outer.alignment = .top
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.widthAnchor.constraint(equalToConstant: width),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        return panel
    }
}
