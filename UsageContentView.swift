import Cocoa

// MARK: - Native Usage View

class UsageContentView: NSView {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let statusDot = NSView()
    var onContentSizeChanged: ((CGFloat) -> Void)?
    private var skeletonShownAt: Date?
    private var lastSections: [UsageSection] = []
    static let barWidth: CGFloat = 368

    /// True when the view has real usage data (not skeleton or empty).
    var hasContent: Bool { !lastSections.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1).cgColor

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        // Stack view inside scroll view
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Status dot
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.gray.cgColor
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)
        NSLayoutConstraint.activate([
            statusDot.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        // Initial loading skeleton (callback not wired yet — size set by AppDelegate)
        showLoadingSkeleton()
    }

    /// The natural height of the skeleton, used to set the initial popover size.
    var skeletonHeight: CGFloat {
        stackView.layoutSubtreeIfNeeded()
        return stackView.fittingSize.height
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(sections: [UsageSection]) {
        // If skeleton is still showing, ensure minimum display time
        if let shown = skeletonShownAt {
            let elapsed = Date().timeIntervalSince(shown)
            let remaining = Timing.skeletonMinDisplay - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.doUpdate(sections: sections)
                }
                return
            }
        }
        doUpdate(sections: sections)
    }

    private func doUpdate(sections: [UsageSection]) {
        let wasShowingSkeleton = skeletonShownAt != nil
        skeletonShownAt = nil

        // Skip full rebuild if the data hasn't changed (unless transitioning
        // from skeleton) — avoids layout churn that causes popover flicker.
        if !wasShowingSkeleton && sections == lastSections {
            return
        }
        lastSections = sections

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if sections.isEmpty {
            let empty = makeLabel("No usage data available", size: 13, color: NSColor(white: 0.5, alpha: 1))
            stackView.addArrangedSubview(empty)
            return
        }

        for (i, section) in sections.enumerated() {
            if i > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
                stackView.addArrangedSubview(spacer)

                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stackView.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
                divider.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true
                stackView.setCustomSpacing(6, after: divider)
            }

            // Section title
            if !section.title.isEmpty {
                let title = makeLabel(section.title.uppercased(), size: 10, weight: .semibold,
                                      color: NSColor(white: 0.5, alpha: 1))
                title.allowsDefaultTighteningForTruncation = true
                stackView.addArrangedSubview(title)
                stackView.setCustomSpacing(6, after: title)
            }

            for meter in section.meters {
                addMeter(meter)
            }
        }

        // Crossfade from skeleton to real content
        if wasShowingSkeleton {
            scrollView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().alphaValue = 1
            }
        }

        stackView.layoutSubtreeIfNeeded()
        let fittingHeight = stackView.fittingSize.height
        onContentSizeChanged?(fittingHeight)
    }

    // MARK: - Loading Skeleton

    func showLoadingSkeleton() {
        skeletonShownAt = Date()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let barWidth = Self.barWidth

        // Simulate 2 sections with 2 meters each
        for section in 0..<2 {
            if section > 0 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
                stackView.addArrangedSubview(spacer)

                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stackView.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 16).isActive = true
                divider.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16).isActive = true
                stackView.setCustomSpacing(6, after: divider)
            }

            // Section title skeleton
            let titleBar = makeShimmerBar(width: 120, height: 10)
            stackView.addArrangedSubview(titleBar)
            stackView.setCustomSpacing(6, after: titleBar)

            for meter in 0..<2 {
                // Label row skeleton
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fill
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

                let nameW: CGFloat = meter == 0 ? 110 : 80
                let nameBar = makeShimmerBar(width: nameW, height: 12, flexible: true)
                let pctBar = makeShimmerBar(width: 32, height: 12)
                pctBar.setContentHuggingPriority(.required, for: .horizontal)
                row.addArrangedSubview(nameBar)
                row.addArrangedSubview(pctBar)

                stackView.addArrangedSubview(row)
                stackView.setCustomSpacing(4, after: row)

                // Progress bar skeleton
                let track = makeShimmerBar(width: barWidth, height: 6, cornerRadius: 3)
                stackView.addArrangedSubview(track)
                stackView.setCustomSpacing(2, after: track)

                // Detail skeleton
                let detailBar = makeShimmerBar(width: meter == 0 ? 130 : 90, height: 10)
                stackView.addArrangedSubview(detailBar)
                stackView.setCustomSpacing(6, after: detailBar)
            }
        }

        stackView.layoutSubtreeIfNeeded()
        onContentSizeChanged?(stackView.fittingSize.height)
    }

    private func makeShimmerBar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4, flexible: Bool = false) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        if flexible {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        view.heightAnchor.constraint(equalToConstant: height).isActive = true

        let base = NSColor(white: 0.18, alpha: 1)
        let highlight = NSColor(white: 0.28, alpha: 1)

        let gradient = CAGradientLayer()
        gradient.colors = [base.cgColor, highlight.cgColor, base.cgColor]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.frame = CGRect(x: 0, y: 0, width: width * 3, height: height)
        view.layer?.addSublayer(gradient)

        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -width * 2
        anim.toValue = 0
        anim.duration = 2.0
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(anim, forKey: "shimmer")

        return view
    }

    private func addMeter(_ meter: UsageMeter) {
        let barWidth = Self.barWidth

        // Label row
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

        let name = makeLabel(meter.label.isEmpty ? "Usage" : meter.label, size: 13, weight: .medium, color: .white)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pct = makeLabel("\(meter.percentage)%", size: 13, weight: .medium,
                            color: colorForPercentage(meter.percentage))
        pct.alignment = .right
        pct.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(name)
        row.addArrangedSubview(pct)
        stackView.addArrangedSubview(row)
        stackView.setCustomSpacing(4, after: row)

        // Progress bar
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        track.layer?.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true
        track.widthAnchor.constraint(equalToConstant: barWidth).isActive = true

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = colorForPercentage(meter.percentage).cgColor
        fill.layer?.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor,
                                        multiplier: max(CGFloat(min(meter.percentage, 100)) / 100.0, 0.01)),
        ])

        stackView.addArrangedSubview(track)

        // Detail
        if !meter.detail.isEmpty {
            stackView.setCustomSpacing(2, after: track)
            let detail = makeLabel(meter.detail, size: 11, color: NSColor(white: 0.45, alpha: 1))
            stackView.addArrangedSubview(detail)
            stackView.setCustomSpacing(6, after: detail)
        } else {
            stackView.setCustomSpacing(6, after: track)
        }
    }

    // MARK: - Status Dot

    func setStatusFresh(_ fresh: Bool) {
        statusDot.layer?.backgroundColor = fresh
            ? NSColor(red: 0x2b/255.0, green: 0xa8/255.0, blue: 0x82/255.0, alpha: 1).cgColor
            : NSColor.gray.cgColor
    }

    func setStatusLoading() {
        statusDot.layer?.backgroundColor = NSColor(red: 0xc0/255.0, green: 0x96/255.0, blue: 0x3a/255.0, alpha: 1).cgColor
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                           color: NSColor = .white) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func colorForPercentage(_ pct: Int) -> NSColor {
        switch pct {
        case 0..<50: return NSColor(red: 0x2b/255.0, green: 0xa8/255.0, blue: 0x82/255.0, alpha: 1)  // deep emerald
        case 50..<80: return NSColor(red: 0xc9/255.0, green: 0x9a/255.0, blue: 0x2e/255.0, alpha: 1)  // muted gold
        case 80..<95: return NSColor(red: 0xc0/255.0, green: 0x5e/255.0, blue: 0x1a/255.0, alpha: 1)  // deep amber
        default: return NSColor(red: 0xb8/255.0, green: 0x3a/255.0, blue: 0x3a/255.0, alpha: 1)       // muted crimson
        }
    }
}
