import AppKit

/// The top of the dropdown: a tab strip (Overview, then one tab per subscription) over a
/// card. Overview keeps the three weekly rows; a subscription tab shows its plan, every
/// window as a bar with "% left" and the reset time, and any note.
@MainActor
final class MenubarPanel: NSView {
    static let width: CGFloat = 320
    private static let pad: CGFloat = 14

    var selectedTab = "overview"
    var onSelect: ((String) -> Void)?

    private let tabs = NSSegmentedControl()
    private let content = NSStackView()
    private var snapshot: MenubarSnapshot?
    private var updatedAt = Date()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        tabs.segmentStyle = .rounded
        tabs.controlSize = .small
        tabs.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        addSubview(tabs)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render(snapshot: MenubarSnapshot, updatedAt: Date) {
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        let ids = ["overview"] + snapshot.cards.map(\.id)
        if !ids.contains(selectedTab) { selectedTab = "overview" }
        tabs.segmentCount = ids.count
        tabs.setLabel("Overview", forSegment: 0)
        for (i, card) in snapshot.cards.enumerated() { tabs.setLabel(card.name, forSegment: i + 1) }
        tabs.selectedSegment = ids.firstIndex(of: selectedTab) ?? 0
        tabs.sizeToFit()
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in rows(snapshot) {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.width - Self.pad * 2).isActive = true
        }
        layoutPanel()
    }

    @objc private func tabChanged() {
        guard let snapshot else { return }
        let ids = ["overview"] + snapshot.cards.map(\.id)
        let idx = tabs.selectedSegment
        guard idx >= 0, idx < ids.count else { return }
        selectedTab = ids[idx]
        onSelect?(selectedTab)
    }

    private func layoutPanel() {
        content.layoutSubtreeIfNeeded()
        let contentHeight = content.fittingSize.height
        let tabHeight = tabs.frame.height
        let total = Self.pad + tabHeight + 10 + contentHeight + Self.pad
        frame = NSRect(x: 0, y: 0, width: Self.width, height: total)
        tabs.frame.origin = NSPoint(x: (Self.width - tabs.frame.width) / 2, y: total - Self.pad - tabHeight)
        content.frame = NSRect(x: Self.pad, y: Self.pad, width: Self.width - Self.pad * 2, height: contentHeight)
        needsDisplay = true
    }

    // MARK: rows

    private func rows(_ snap: MenubarSnapshot) -> [NSView] {
        let now = Date()
        if selectedTab == "overview" || snap.cards.isEmpty {
            var views: [NSView] = []
            if snap.cards.isEmpty {
                views.append(label("No plan window in any local file yet.", size: 12, color: .secondaryLabelColor))
            }
            for card in snap.cards {
                guard let week = card.windows.last(where: { $0.label.hasSuffix("weekly") }) ?? card.windows.first else { continue }
                views.append(twoSided(card.name, right: card.plan ?? "", bold: true))
                views.append(bar(week.pctUsed))
                views.append(twoSided("\(max(0, 100 - week.pctUsed))% left", right: MenubarSnapshot.resetsLabel(week.resetsAt, now: now), size: 11, color: .secondaryLabelColor))
            }
            views.append(spacer(4))
            views.append(twoSided(snap.spendLine, right: updatedLine(), size: 11, color: .secondaryLabelColor))
            return views
        }
        guard let card = snap.cards.first(where: { $0.id == selectedTab }) else { return [] }
        var views: [NSView] = []
        views.append(twoSided(card.name, right: card.plan ?? "", bold: true))
        views.append(twoSided(updatedLine(), right: "", size: 11, color: .secondaryLabelColor))
        views.append(spacer(4))
        for w in card.windows {
            views.append(label(w.label, size: 13))
            views.append(bar(w.pctUsed))
            views.append(twoSided("\(max(0, 100 - w.pctUsed))% left", right: MenubarSnapshot.resetsLabel(w.resetsAt, now: now), size: 11, color: .secondaryLabelColor))
        }
        if let usd = card.usdLine {
            views.append(spacer(2))
            views.append(label(usd, size: 12))
        }
        if let note = card.note {
            views.append(label(note, size: 11, color: .secondaryLabelColor, wraps: true))
        }
        return views
    }

    private func updatedLine() -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "Updated \(f.string(from: updatedAt))"
    }

    private func label(_ text: String, size: CGFloat, color: NSColor = .labelColor, bold: Bool = false, wraps: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        l.textColor = color
        l.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        l.maximumNumberOfLines = wraps ? 3 : 1
        l.preferredMaxLayoutWidth = Self.width - Self.pad * 2
        return l
    }

    private func twoSided(_ left: String, right: String, size: CGFloat = 13, color: NSColor = .labelColor, bold: Bool = false) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        let l = label(left, size: size, color: color, bold: bold)
        let r = label(right, size: size, color: color)
        r.alignment = .right
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        r.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(l)
        row.addArrangedSubview(r)
        return row
    }

    private func bar(_ pctUsed: Int) -> NSView {
        let v = BarView(fraction: Double(max(0, 100 - pctUsed)) / 100)
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
}

/// Rounded track with a fill for the part of the window still left.
@MainActor
final class BarView: NSView {
    let fraction: Double
    init(fraction: Double) {
        self.fraction = min(1, max(0, fraction))
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let color: NSColor = fraction > 0.5 ? .systemGreen : fraction > 0.2 ? .systemOrange : .systemRed
        color.setFill()
        let w = max(bounds.height, bounds.width * fraction)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}
