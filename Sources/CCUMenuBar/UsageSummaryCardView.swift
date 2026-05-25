import AppKit

final class UsageSummaryCardView: NSView {
    private let summary: UsageSummary

    init(summary: UsageSummary) {
        self.summary = summary
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if summary.hasUsage {
            drawContent()
        } else {
            drawEmptyState()
        }
    }

    private func drawContent() {
        metric(label: "Today tokens", value: Formatters.compactTokens(summary.todayTokens), x: 22, y: 10)
        metric(label: "30d tokens", value: Formatters.compactTokens(summary.thirtyDayTokens), x: 190, y: 10)
        metric(label: "Latest tokens", value: summary.latestTokens.map(Formatters.compactTokens) ?? "--", x: 22, y: 40)
        drawBars()

        drawText(
            "Top model: \(summary.topModel ?? "unknown")",
            rect: NSRect(x: 22, y: 114, width: 316, height: 18),
            font: .menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func drawEmptyState() {
        drawText(
            "No local usage found",
            rect: NSRect(x: 22, y: 44, width: 316, height: 22),
            font: .menuFont(ofSize: 0),
            color: .labelColor
        )
        drawText(
            "Run Claude Code, then reopen this menu after a response is logged.",
            rect: NSRect(x: 22, y: 70, width: 316, height: 44),
            font: .menuFont(ofSize: 0),
            color: .secondaryLabelColor
        )
    }

    private func metric(label: String, value: String, x: CGFloat, y: CGFloat) {
        drawText(
            label,
            rect: NSRect(x: x, y: y, width: 148, height: 18),
            font: .menuFont(ofSize: 0),
            color: .secondaryLabelColor
        )
        drawText(
            value,
            rect: NSRect(x: x, y: y + 17, width: 148, height: 18),
            font: .menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func drawBars() {
        let values = summary.dailySeries.map(\.tokens)
        let maxValue = max(values.max() ?? 0, 1)
        let chart = NSRect(x: 22, y: 76, width: 316, height: 30)
        let gap: CGFloat = 3
        let barWidth = max(2, floor((chart.width - gap * CGFloat(max(values.count - 1, 0))) / CGFloat(max(values.count, 1))))
        let brand = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.06, alpha: 1)

        for (index, value) in values.enumerated() {
            let ratio = CGFloat(value) / CGFloat(maxValue)
            let height = max(value == 0 ? 2 : 4, ratio * chart.height)
            let x = chart.minX + CGFloat(index) * (barWidth + gap)
            let y = chart.maxY - height
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            brand.withAlphaComponent(value == 0 ? 0.25 : 0.9).setFill()
            path.fill()
        }
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
