import AppKit
import SwiftUI

private struct TimelineRange {
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

private enum TimelineCoordinateSpace {
    static let name = "timeline"
}

private enum TimelineLayout {
    static let pointsPerHour: CGFloat = 96
    static let timeGutter: CGFloat = 70
    static let trailingInset: CGFloat = 14
    static let selectionRailWidth: CGFloat = 42
    static let selectionRailSpacing: CGFloat = 8
}

struct TimelineView: View {
    @EnvironmentObject private var state: AppState
    @State private var gesturePreview: DateInterval?
    @State private var draftInterval: DateInterval?
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let day = calendar.dayInterval(containing: state.selectedDate)
        let blocks = state.blocksForSelectedDay(calendar: calendar)
        let range = TimelineRange(start: day.start, end: day.end)

        GeometryReader { proxy in
            let timelineWidth = max(
                320,
                proxy.size.width - TimelineLayout.selectionRailWidth - TimelineLayout.selectionRailSpacing
            )
            let contentWidth = timelineWidth
            let fullDayHeight = CGFloat(range.duration / 3600) * TimelineLayout.pointsPerHour
            let contentHeight = max(proxy.size.height, fullDayHeight)
            let pointsPerSecond = contentHeight / CGFloat(range.duration)
            let blockWidth = max(
                120,
                contentWidth - TimelineLayout.timeGutter - TimelineLayout.trailingInset
            )

            HStack(spacing: TimelineLayout.selectionRailSpacing) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        TimelineScrollAnchors(
                            range: range,
                            pointsPerSecond: pointsPerSecond,
                            calendar: calendar
                        )

                        TimelineGrid(
                            range: range,
                            contentWidth: contentWidth,
                            contentHeight: contentHeight,
                            timeGutter: TimelineLayout.timeGutter,
                            trailingInset: TimelineLayout.trailingInset,
                            calendar: calendar
                        )

                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(width: contentWidth, height: contentHeight)
                            .gesture(
                                SpatialTapGesture(count: 2)
                                    .exclusively(before: SpatialTapGesture(count: 1))
                                    .onEnded { value in
                                        switch value {
                                        case .first(let doubleClick):
                                            beginDraft(
                                                atY: doubleClick.location.y,
                                                range: range,
                                                pointsPerSecond: pointsPerSecond
                                            )
                                        case .second:
                                            state.selectedBlockID = nil
                                        }
                                    }
                            )

                        ForEach(blocks) { block in
                            if block.intersection(with: day, now: state.now) != nil {
                                TimelineBlockView(
                                    block: block,
                                    day: day,
                                    rangeStart: range.start,
                                    pointsPerSecond: pointsPerSecond,
                                    leadingInset: TimelineLayout.timeGutter,
                                    blockWidth: blockWidth,
                                    selected: state.selectedBlockID == block.id,
                                    onPreview: { gesturePreview = $0 }
                                )
                                .environmentObject(state)
                            }
                        }

                        if let draftInterval {
                            HistoricalDraftView(
                                interval: draftInterval,
                                rangeStart: range.start,
                                pointsPerSecond: pointsPerSecond,
                                leadingInset: TimelineLayout.timeGutter,
                                blockWidth: blockWidth,
                                onCommit: { name, description in
                                    if state.createHistorical(
                                        name: name,
                                        description: description,
                                        start: draftInterval.start,
                                        end: draftInterval.end
                                    ) {
                                        self.draftInterval = nil
                                    }
                                },
                                onCancel: { self.draftInterval = nil }
                            )
                        }

                        if state.now >= day.start, state.now < day.end {
                            Capsule()
                                .fill(.red.opacity(0.9))
                                .frame(width: blockWidth, height: 2)
                                .offset(
                                    x: TimelineLayout.timeGutter,
                                    y: CGFloat(state.now.timeIntervalSince(range.start)) * pointsPerSecond - 1
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .background(RightDragScrollSupport())
                    .coordinateSpace(name: TimelineCoordinateSpace.name)
                    .frame(width: contentWidth, height: contentHeight)
                    }
                    .scrollIndicators(.visible)
                    .task(id: day.start) {
                        await Task.yield()
                        scrollProxy.scrollTo(
                            initialScrollTarget(for: day, blocks: blocks),
                            anchor: .top
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        if let gesturePreview {
                            TimelineGesturePreview(interval: gesturePreview)
                                .padding(.top, 8)
                                .padding(.trailing, 12)
                        }
                    }
                }
                .frame(width: timelineWidth, height: proxy.size.height)

                TimelineSelectionRail(blocks: blocks)
                    .frame(width: TimelineLayout.selectionRailWidth, height: proxy.size.height)
            }
        }
        .accessibilityLabel("Vertical daily time block timeline")
    }

    private func beginDraft(atY y: CGFloat, range: TimelineRange, pointsPerSecond: CGFloat) {
        let seconds = TimeInterval(y / pointsPerSecond)
        let proposed = range.start.addingTimeInterval(seconds)
        draftInterval = state.availableHistoricalInterval(at: proposed, calendar: calendar)
    }

    private func initialScrollTarget(for day: DateInterval, blocks: [TimeBlock]) -> Date {
        let earliest = blocks
            .compactMap { $0.intersection(with: day, now: state.now)?.start }
            .min()
        let fallback = calendar.date(byAdding: .hour, value: 8, to: day.start) ?? day.start
        let contextualStart = earliest.flatMap {
            calendar.date(byAdding: .hour, value: -1, to: $0)
        } ?? fallback
        let clamped = max(day.start, contextualStart)
        return calendar.dateInterval(of: .hour, for: clamped)?.start ?? day.start
    }
}

private struct TimelineSelectionRail: View {
    @EnvironmentObject private var state: AppState
    let blocks: [TimeBlock]

    private let spacing: CGFloat = 3
    private let inset: CGFloat = 6
    private let minimumSegmentHeight: CGFloat = 22
    private let maximumSegmentHeight: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let gapHeight = CGFloat(max(0, blocks.count - 1)) * spacing
            let availableHeight = max(0, proxy.size.height - (inset * 2) - gapHeight)
            let fittedHeight = blocks.isEmpty
                ? maximumSegmentHeight
                : availableHeight / CGFloat(blocks.count)
            let segmentHeight = min(maximumSegmentHeight, max(minimumSegmentHeight, fittedHeight))

            ScrollView(.vertical) {
                LazyVStack(spacing: spacing) {
                    ForEach(blocks) { block in
                        TimelineSelectionSegment(
                            block: block,
                            selected: state.selectedBlockID == block.id,
                            height: segmentHeight
                        ) {
                            state.selectedBlockID = block.id
                        }
                    }
                }
                .padding(inset)
            }
            .scrollIndicators(.hidden)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time block selection rail")
    }
}

private struct TimelineSelectionSegment: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    let block: TimeBlock
    let selected: Bool
    let height: CGFloat
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(eventAppearances.color(for: block.name))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            selected ? eventAppearances.labelColor(for: block.name) : Color.clear,
                            lineWidth: 2
                        )
                        .padding(1)
                }
                .frame(height: height)
                .scaleEffect(hovered ? 1.12 : 1)
                .shadow(
                    color: .black.opacity(hovered ? 0.22 : 0),
                    radius: hovered ? 4 : 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .zIndex(hovered ? 1 : 0)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: hovered)
        .help([
            block.name,
            block.description,
            TimeText.interval(start: block.startedAt, end: block.effectiveEnd(now: state.now))
        ].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(block.name)
        .accessibilityValue(block.stopLabel)
    }
}

private struct TimelineScrollAnchors: View {
    let range: TimelineRange
    let pointsPerSecond: CGFloat
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 0) {
            ForEach(hourSegments, id: \.start) { segment in
                Color.clear
                    .frame(width: 1, height: CGFloat(segment.duration) * pointsPerSecond)
                    .id(segment.start)
            }
        }
        .allowsHitTesting(false)
    }

    private var hourSegments: [DateInterval] {
        var result: [DateInterval] = []
        var start = range.start
        while start < range.end {
            let proposedEnd = calendar.date(byAdding: .hour, value: 1, to: start) ?? range.end
            let end = min(proposedEnd, range.end)
            guard end > start else { break }
            result.append(DateInterval(start: start, end: end))
            start = end
        }
        return result
    }
}

private struct RightDragScrollSupport: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.didAttach = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(to: view.enclosingScrollView)
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.attach(to: nsView.enclosingScrollView)
    }

    static func dismantleNSView(_ nsView: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        var didAttach: ((AttachmentView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            didAttach?(self)
        }
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        private weak var scrollView: NSScrollView?
        private var startingOrigin: NSPoint?

        private lazy var panGesture: NSPanGestureRecognizer = {
            let gesture = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            gesture.buttonMask = 0x2
            gesture.delegate = self
            return gesture
        }()

        func attach(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else { return }
            detach()
            self.scrollView = scrollView
            scrollView?.addGestureRecognizer(panGesture)
        }

        func detach() {
            if let scrollView {
                scrollView.removeGestureRecognizer(panGesture)
            }
            scrollView = nil
            startingOrigin = nil
        }

        @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let scrollView else { return }
            let clipView = scrollView.contentView

            switch gesture.state {
            case .began:
                startingOrigin = clipView.bounds.origin
            case .changed:
                guard var origin = startingOrigin,
                      let documentView = scrollView.documentView else { return }
                let translation = gesture.translation(in: scrollView)
                let documentBounds = documentView.bounds
                let minimumY = documentBounds.minY
                let maximumY = max(minimumY, documentBounds.maxY - clipView.bounds.height)
                origin.y = min(max(origin.y - translation.y, minimumY), maximumY)
                clipView.scroll(to: origin)
                scrollView.reflectScrolledClipView(clipView)
            case .ended, .cancelled, .failed:
                startingOrigin = nil
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct TimelineGrid: View {
    let range: TimelineRange
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let timeGutter: CGFloat
    let trailingInset: CGFloat
    let calendar: Calendar

    private var hourTicks: [Date] {
        var ticks: [Date] = []
        var tick = calendar.dateInterval(of: .hour, for: range.start)?.start ?? range.start
        if tick < range.start { tick = calendar.date(byAdding: .hour, value: 1, to: tick) ?? range.start }
        while tick <= range.end {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: tick), next > tick else { break }
            tick = next
        }
        return ticks
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))

            ForEach(hourTicks, id: \.self) { tick in
                let y = CGFloat(tick.timeIntervalSince(range.start) / range.duration) * contentHeight
                let labelY = min(max(0, y - 8), contentHeight - 16)

                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: timeGutter - 12, alignment: .trailing)
                    .offset(y: labelY)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(
                        width: max(1, contentWidth - timeGutter - trailingInset),
                        height: 1
                    )
                    .offset(x: timeGutter, y: y - 0.5)
            }
        }
        .frame(width: contentWidth, height: contentHeight)
    }
}

private struct TimelineBlockView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    let block: TimeBlock
    let day: DateInterval
    let rangeStart: Date
    let pointsPerSecond: CGFloat
    let leadingInset: CGFloat
    let blockWidth: CGFloat
    let selected: Bool
    let onPreview: (DateInterval?) -> Void

    @State private var proposal: DateInterval?
    private let calendar = Calendar.autoupdatingCurrent

    private var fullInterval: DateInterval {
        DateInterval(start: block.startedAt, end: block.effectiveEnd(now: state.now))
    }

    private var displayedInterval: DateInterval {
        let interval = proposal ?? fullInterval
        let start = max(interval.start, day.start)
        let end = max(start, min(interval.end, day.end))
        return DateInterval(start: start, end: end)
    }

    private var editedInterval: DateInterval {
        proposal ?? fullInterval
    }

    private var blockHeight: CGFloat {
        max(4, CGFloat(displayedInterval.duration) * pointsPerSecond)
    }

    private var visualHeight: CGFloat {
        max(2, blockHeight - 3)
    }

    private var y: CGFloat {
        CGFloat(displayedInterval.start.timeIntervalSince(rangeStart)) * pointsPerSecond
    }

    private var crossesDayBoundary: Bool {
        guard let end = block.endedAt else { return false }
        return end > calendar.dayInterval(containing: block.startedAt).end
    }

    private var showStartHandle: Bool { !block.isActive && day.contains(block.startedAt) }
    private var showEndHandle: Bool {
        guard let end = block.endedAt else { return false }
        return day.contains(end)
    }

    private var showsDescription: Bool {
        block.description != nil && visualHeight >= 38
    }

    private var helpText: String {
        [block.name, block.description, block.stopLabel]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(eventAppearances.color(for: block.name))

            if visualHeight >= 17 {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        if let icon = eventAppearances.icon(for: block.name) {
                            Image(systemName: icon)
                                .font(.caption.weight(.semibold))
                        }

                        Text(block.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        Text(TimeText.interval(start: editedInterval.start, end: editedInterval.end))
                            .font(.caption2)
                            .foregroundStyle(eventAppearances.labelColor(for: block.name).opacity(0.62))
                            .fixedSize()
                            .layoutPriority(1)
                    }

                    if showsDescription, let description = block.description {
                        Text(description)
                            .font(.caption2)
                            .lineLimit(1)
                            .opacity(0.78)
                    }

                    if !block.isActive, visualHeight >= (showsDescription ? 58 : 42) {
                        Text(block.stopLabel)
                            .font(.caption2)
                            .lineLimit(1)
                            .opacity(0.72)
                    }
                }
                .foregroundStyle(eventAppearances.labelColor(for: block.name))
                .padding(.horizontal, 12)
                .padding(.vertical, visualHeight < 42 ? 2 : 6)
                .frame(width: blockWidth, height: visualHeight, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
            }

            if selected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.primary, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }

            if showStartHandle {
                VStack {
                    resizeHitTarget(for: .start)
                    Spacer(minLength: 0)
                }
            }

            if showEndHandle {
                VStack {
                    Spacer(minLength: 0)
                    resizeHitTarget(for: .end)
                }
            }
        }
        .frame(width: blockWidth, height: visualHeight)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .offset(x: leadingInset, y: y)
        .onTapGesture { state.selectedBlockID = block.id }
        .gesture(bodyGesture)
        .contextMenu {
            if !block.isActive {
                Button("Continue on Task", systemImage: "play.fill") {
                    state.selectedBlockID = block.id
                    state.continueBlock(id: block.id)
                }

                Divider()

                Button("Delete", role: .destructive) {
                    state.selectedBlockID = block.id
                    state.deleteSelected()
                }
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var bodyGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineCoordinateSpace.name))
            .onChanged { value in
                guard !block.isActive, !crossesDayBoundary, let end = block.endedAt else { return }
                let delta = TimeInterval((value.location.y - value.startLocation.y) / pointsPerSecond)
                updateProposal(
                    mode: .move,
                    proposedStart: block.startedAt.addingTimeInterval(delta),
                    proposedEnd: end.addingTimeInterval(delta)
                )
            }
            .onEnded { _ in commitProposal() }
    }

    private func resizeHitTarget(for mode: TimelineEditMode) -> some View {
        Color.clear
            .frame(width: blockWidth, height: min(10, visualHeight / 2))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeUpDown.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .highPriorityGesture(editGesture(mode))
    }

    private func editGesture(_ mode: TimelineEditMode) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.name))
            .onChanged { value in
                guard let end = block.endedAt else { return }
                let delta = TimeInterval((value.location.y - value.startLocation.y) / pointsPerSecond)
                switch mode {
                case .start:
                    updateProposal(
                        mode: .start,
                        proposedStart: block.startedAt.addingTimeInterval(delta),
                        proposedEnd: end
                    )
                case .end:
                    updateProposal(
                        mode: .end,
                        proposedStart: block.startedAt,
                        proposedEnd: end.addingTimeInterval(delta)
                    )
                case .move:
                    break
                }
            }
            .onEnded { _ in commitProposal() }
    }

    private func updateProposal(mode: TimelineEditMode, proposedStart: Date, proposedEnd: Date) {
        let interval = state.clampedInterval(
            for: block,
            proposedStart: proposedStart,
            proposedEnd: proposedEnd,
            mode: mode,
            calendar: calendar
        )
        proposal = interval
        onPreview(interval)
    }

    private func commitProposal() {
        guard let proposal else { return }
        state.updateTiming(id: block.id, start: proposal.start, end: proposal.end)
        self.proposal = nil
        onPreview(nil)
    }
}

private struct HistoricalDraftView: View {
    let interval: DateInterval
    let rangeStart: Date
    let pointsPerSecond: CGFloat
    let leadingInset: CGFloat
    let blockWidth: CGFloat
    let onCommit: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var description = ""
    @FocusState private var nameFocused: Bool

    private var y: CGFloat {
        CGFloat(interval.start.timeIntervalSince(rangeStart)) * pointsPerSecond
    }

    private var height: CGFloat {
        max(44, CGFloat(interval.duration) * pointsPerSecond)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $name)
                    .font(.caption.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(submit)

                TextField("Description (optional)", text: $description)
                    .font(.caption2)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
            }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .onExitCommand(perform: onCancel)
        }
        .frame(width: blockWidth, height: height)
        .offset(x: leadingInset, y: y)
        .onAppear { nameFocused = true }
        .help("\(TimeText.interval(start: interval.start, end: interval.end)) — \(TimeText.duration(interval.duration))")
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed, BlockDescription.normalized(description))
    }
}

private struct TimelineGesturePreview: View {
    let interval: DateInterval

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(TimeText.interval(start: interval.start, end: interval.end))
                .font(.callout.weight(.medium))
            Text(TimeText.duration(interval.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
