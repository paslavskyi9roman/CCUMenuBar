import AppKit

/// Custom view for the "Reload now" menu item. The vanilla `target:action:`
/// NSMenuItem closes the menu the instant it's clicked, so the user has no way
/// to tell the click registered when `state.json` hasn't changed. This view
/// keeps the menu open, shows an inline spinner + "Reloading…" label, and
/// holds that state for a minimum duration so the feedback is actually visible
/// even though re-reading the file is essentially instant.
@MainActor
final class RefreshMenuItemView: NSView {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "Reload now")
    private let spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.controlSize = .small
        p.isIndeterminate = true
        p.isDisplayedWhenStopped = false
        return p
    }()
    private let highlight: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .selection
        v.state = .active
        v.isEmphasized = true
        v.blendingMode = .behindWindow
        v.isHidden = true
        return v
    }()

    private var isLoading = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    /// Minimum time the loading state is held so the spinner is actually seen,
    /// even though `readNow()` returns in single-digit ms.
    private static let minimumLoadingDuration: TimeInterval = 0.7

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        wantsLayer = true
        autoresizingMask = [.width]
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // Without this, clicks land on `label` / `highlight` instead of `self`, so
    // `mouseDown` never fires here — NSMenu then treats the click as activation
    // of a no-action item and dismisses the menu.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isLoading else { return }
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    // Handle clicks in mouseDown — NSMenu's tracking session can dismiss the
    // menu on mouseUp before a mouseUp override would run.
    override func mouseDown(with event: NSEvent) {
        guard !isLoading else { return }
        startLoading()
        onClick?()
    }

    private func startLoading() {
        isLoading = true
        isHovered = false
        label.stringValue = "Reloading…"
        spinner.startAnimation(nil)
        applyAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumLoadingDuration) { [weak self] in
            self?.finishLoading()
        }
    }

    private func finishLoading() {
        isLoading = false
        label.stringValue = "Reload now"
        spinner.stopAnimation(nil)
        applyAppearance()
    }

    private func applyAppearance() {
        highlight.isHidden = !isHovered
        if isHovered {
            label.textColor = .selectedMenuItemTextColor
        } else if isLoading {
            label.textColor = .secondaryLabelColor
        } else {
            label.textColor = .labelColor
        }
    }
}
