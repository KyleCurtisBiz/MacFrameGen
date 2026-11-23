import AppKit

/// The on-screen display: one small, quiet frame-rate counter in the top-left corner. Everything else the app
/// measures is in the optional detailed line (Advanced menu).
@MainActor
final class HUD {
    // Neutral slate, no accent colours: it sits on top of a game and should not compete with it.
    private static let slate = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.74)
    private static let primary = NSColor(white: 1, alpha: 0.92)
    private static let secondary = NSColor(white: 1, alpha: 0.58)

    private let panel = NSView()
    private let text = NSTextField(labelWithString: "")
    private let detailBack = NSView()
    private let detail = NSTextField(labelWithString: "")
    private let toastBack = NSView()
    private let toast = NSTextField(labelWithString: "")
    private var toastToken = 0

    var visible = true { didSet { apply() } }
    /// The full line of numbers underneath, for diagnosing problems.
    var detailed = false { didSet { apply() } }
    /// False while there is nothing to report (no capture card), so stale numbers are not shown.
    var live = false { didSet { apply() } }

    init(in parent: NSView) {
        func box(_ back: NSView, _ label: NSTextField, radius: CGFloat, padX: CGFloat, padY: CGFloat) {
            back.wantsLayer = true
            back.layer?.backgroundColor = HUD.slate.cgColor
            back.layer?.cornerRadius = radius
            back.layer?.cornerCurve = .continuous
            back.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            back.addSubview(label)
            parent.addSubview(back)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: padX),
                label.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -padX),
                label.topAnchor.constraint(equalTo: back.topAnchor, constant: padY),
                label.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -padY),
            ])
        }
        box(panel, text, radius: 6, padX: 8, padY: 3.5)
        box(detailBack, detail, radius: 6, padX: 8, padY: 3.5)
        box(toastBack, toast, radius: 8, padX: 11, padY: 5)
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = HUD.secondary
        toast.font = .systemFont(ofSize: 12, weight: .medium)
        toast.textColor = HUD.primary
        toastBack.alphaValue = 0
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
            panel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 12),
            detailBack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
            detailBack.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 5),
            detailBack.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -12),
            toastBack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            toastBack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -28),
            toastBack.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor, constant: -40),
        ])
        apply()
    }

    private func apply() {
        panel.isHidden = !visible || !live
        detailBack.isHidden = !detailed || !live
    }

    /// Call once a second with the engine's figures.
    func update(_ s: Engine.Stats) {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let plain = NSFont.systemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        func add(_ t: String, _ font: NSFont, _ colour: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: colour])) }

        // "30 → 60 fps": what the console sends, then what reaches the display. One number when they are the same.
        if s.generated > 0 {
            add("\(s.real)", digits, HUD.secondary)
            add("  →  ", plain, HUD.secondary)
        }
        add("\(s.shown)", digits, HUD.primary)
        add(" fps", plain, HUD.secondary)
        text.attributedStringValue = out
        detail.stringValue = s.line
    }

    /// A short message at the bottom of the picture that fades by itself.
    func say(_ message: String, seconds: Double = 1.6) {
        toast.stringValue = message
        toastToken += 1
        let token = toastToken
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; toastBack.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toastToken == token else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; self.toastBack.animator().alphaValue = 0 }
        }
    }
}
