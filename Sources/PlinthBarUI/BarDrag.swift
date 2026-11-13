import SwiftUI
import AppKit
import PlinthModel

/// Dragging on the bar, done by hand rather than with system drag sessions: a `DragGesture` on each
/// draggable piece reports the pointer in the sites row's coordinate space, and this model works out
/// what a drop there would mean.
///
/// The row never rearranges during a drag. The dragged item follows the pointer, lifted, and the
/// outcome is shown in place: an accent insertion line in the gap it would move to, or, after the
/// pointer rests on the middle of another page, that page lit up for a split. Keeping everything
/// else still means the page under the pointer stays under the pointer, so "rest on a page to
/// split" and "pass between pages to reorder" never fight. On drop the bar reports one action and
/// the item springs into its new place.
@MainActor @Observable
final class BarDragModel {
    /// The named coordinate space of the sites row.
    nonisolated static let space = "plinth.bar.sites"
    /// Pointer travel before a press becomes a drag, so clicks still select.
    static let minimumDistance: CGFloat = 4
    /// How long the pointer rests on the middle of a page before it is offered for a split.
    static let splitDwell: Duration = .milliseconds(320)
    /// This far above or below the row, letting go cancels.
    static let verticalCancel: CGFloat = 36

    enum Subject: Equatable {
        /// A whole site: by the capsule's icon, a collapsed item, or a single-page site's button
        /// (`page` set, so that one can also be dropped on another page to split).
        case site(SiteID, page: PageID?)
        /// A page inside a capsule.
        case page(PageID, site: SiteID)

        var page: PageID? {
            switch self {
            case .site(_, let page): return page
            case .page(let page, _): return page
            }
        }
    }

    enum Outcome: Equatable {
        case none
        case moveSite(SiteID, toIndex: Int)
        case movePage(PageID, toIndex: Int)
        case split(PageID, onto: PageID)
    }

    // MARK: Observed by the views

    private(set) var subject: Subject?
    /// Horizontal pointer travel since the drag began.
    private(set) var translation: CGFloat = 0
    /// Where the insertion line is drawn, in the row's space; nil when none is shown.
    private(set) var markerX: CGFloat?
    /// The page lit up as the split target.
    private(set) var splitTarget: PageID?

    // MARK: Not observed

    /// Live frames in the row's space, reported by the items themselves.
    @ObservationIgnored var siteFrames: [SiteID: CGRect] = [:]
    @ObservationIgnored var pageFrames: [PageID: CGRect] = [:]
    /// The row as it was when the drag began.
    @ObservationIgnored private var sites: [(id: SiteID, frame: CGRect, pages: [(id: PageID, frame: CGRect)])] = []
    @ObservationIgnored private var start: CGPoint = .zero
    @ObservationIgnored private var outcome: Outcome = .none
    @ObservationIgnored private var candidate: PageID?
    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var lastEnded: ContinuousClock.Instant?
    @ObservationIgnored private let gap: CGFloat

    init(itemGap: CGFloat) { gap = itemGap }

    // MARK: Queries

    var isDragging: Bool { subject != nil }

    /// True while dragging and just after, so the button under the pointer does not also take the
    /// release as a click.
    var suppressesClick: Bool {
        if subject != nil { return true }
        guard let lastEnded else { return false }
        return ContinuousClock.now - lastEnded < .milliseconds(250)
    }

    func isDragging(site: SiteID) -> Bool {
        if case .site(site, _) = subject { return true }
        return false
    }

    func isDragging(page: PageID) -> Bool {
        if case .page(page, _) = subject { return true }
        return false
    }

    /// The item, or something inside it, is being dragged: draw it above its neighbours.
    func contains(site: SiteID) -> Bool {
        switch subject {
        case .site(let id, _): return id == site
        case .page(_, let id): return id == site
        case nil: return false
        }
    }

    // MARK: Gesture

    func gesture(for subject: Subject) -> some Gesture {
        DragGesture(minimumDistance: Self.minimumDistance, coordinateSpace: .named(Self.space))
            .onChanged { [weak self] value in
                guard let self else { return }
                if self.subject == nil { self.begin(subject, at: value.startLocation) }
                guard self.subject == subject else { return }
                self.move(to: value.location)
            }
            .onEnded { [weak self] _ in
                guard let self, self.subject == subject else { return }
                self.finish()
            }
    }

    /// The row as last drawn, set by the bar on every render.
    @ObservationIgnored var layout = BarLayout(pins: [], sites: [], sitesWidth: 0, sitesAvailable: 0, scrolls: false)
    /// Reports a drop; the bar turns it into a `BarAction`.
    @ObservationIgnored var onDrop: (Outcome) -> Void = { _ in }
    /// How the dropped item settles (nil with Reduce Motion).
    @ObservationIgnored var dropAnimation: Animation?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var lastMove = ContinuousClock.now

    private func begin(_ subject: Subject, at point: CGPoint) {
        sites = layout.sites.map { site in
            (id: site.id,
             frame: siteFrames[site.id] ?? .zero,
             pages: site.form == .capsule ? site.pages.map { (id: $0.id, frame: pageFrames[$0.id] ?? .zero) } : [])
        }
        // A single-page site's page is a split source and target too, at the site's own frame.
        for (i, site) in layout.sites.enumerated() where site.form == .single {
            if let page = site.pages.first { sites[i].pages = [(id: page.id, frame: pageFrames[page.id] ?? sites[i].frame)] }
        }
        start = point
        self.subject = subject
        translation = 0
        cancelled = false
        lastMove = .now
        startWatch()
    }

    /// While a drag is on: Escape puts the item back (the rest of the drag does nothing), and a drag
    /// whose gesture vanished without ending (its view was rebuilt mid-drag) is cleared once the
    /// button is up, so the bar can never be left stuck. Polled, because while SwiftUI tracks the
    /// drag no other events, key presses included, are delivered.
    private func startWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.subject != nil else { return }
                if !self.cancelled, CGEventSource.keyState(.combinedSessionState, key: 53) {   // Escape
                    self.cancelDrag()
                }
                if NSEvent.pressedMouseButtons & 1 == 0, ContinuousClock.now - self.lastMove > .milliseconds(1500) {
                    self.outcome = .none
                    self.finish()
                    return
                }
            }
        }
    }

    /// Puts the item back; the gesture runs on until the button comes up, inertly.
    private func cancelDrag() {
        cancelled = true
        dwell?.cancel()
        candidate = nil
        outcome = .none
        withAnimation(dropAnimation) {
            translation = 0
            markerX = nil
            splitTarget = nil
        }
    }

    private func move(to point: CGPoint) {
        lastMove = .now
        guard !cancelled else { return }
        translation = point.x - start.x
        let next = resolve(point)

        // Splits wait for the pointer to rest on the page's middle.
        if case .split(_, let target) = next {
            if candidate != target {
                candidate = target
                splitTarget = nil
                dwell?.cancel()
                dwell = Task { [weak self] in
                    try? await Task.sleep(for: Self.splitDwell)
                    guard !Task.isCancelled, let self, self.candidate == target else { return }
                    self.splitTarget = target
                    self.outcome = next
                }
            }
            if splitTarget != target { outcome = .none }
            markerX = nil
            return
        }

        candidate = nil
        dwell?.cancel()
        splitTarget = nil
        outcome = next
        markerX = marker(for: next)
    }

    private func finish() {
        let result = outcome
        lastEnded = .now
        withAnimation(dropAnimation) {
            reset()
            if result != .none { onDrop(result) }
        }
    }

    private func reset() {
        dwell?.cancel()
        dwell = nil
        candidate = nil
        subject = nil
        translation = 0
        markerX = nil
        splitTarget = nil
        outcome = .none
        sites = []
        cancelled = false
        watch?.cancel()
        watch = nil
    }

    // MARK: Working out the drop

    private func resolve(_ p: CGPoint) -> Outcome {
        guard let subject, let origin = sites.first?.frame,
              p.y > origin.minY - Self.verticalCancel - 8, p.y < origin.maxY + Self.verticalCancel + 8
        else { return .none }

        if let page = subject.page, let target = splitTarget(at: p, excluding: page) {
            return .split(page, onto: target)
        }

        switch subject {
        case .site(let id, _):
            // Over the pins, the new-page button or beyond, a drop does nothing.
            guard let from = sites.firstIndex(where: { $0.id == id }), let first = sites.first, let last = sites.last,
                  p.x > first.frame.minX - 2 * gap, p.x < last.frame.maxX + 2 * gap
            else { return .none }
            let others = sites.enumerated().filter { $0.offset != from }.map(\.element.frame)
            let to = others.filter { $0.midX < p.x }.count
            return to == from ? .none : .moveSite(id, toIndex: to)

        case .page(let id, let siteID):
            guard let site = sites.first(where: { $0.id == siteID }),
                  let from = site.pages.firstIndex(where: { $0.id == id }),
                  p.x > site.frame.minX - gap, p.x < site.frame.maxX + gap
            else { return .none }   // outside its own capsule a page does not reorder anything
            let others = site.pages.enumerated().filter { $0.offset != from }.map(\.element.frame)
            let to = others.filter { $0.midX < p.x }.count
            return to == from ? .none : .movePage(id, toIndex: to)
        }
    }

    /// The page whose middle half is under the pointer, other than the one being dragged.
    private func splitTarget(at p: CGPoint, excluding dragged: PageID) -> PageID? {
        for site in sites {
            for page in site.pages where page.id != dragged {
                let f = page.frame
                let inset = max(8, f.width * 0.25)
                if p.x > f.minX + inset, p.x < f.maxX - inset, p.y > f.minY - 6, p.y < f.maxY + 6 { return page.id }
            }
        }
        return nil
    }

    /// The middle of the gap the item would land in.
    private func marker(for outcome: Outcome) -> CGFloat? {
        switch outcome {
        case .moveSite(let id, let to):
            let others = sites.filter { $0.id != id }.map(\.frame)
            return gapX(others, at: to, spacing: gap)
        case .movePage(let id, let to):
            guard let site = sites.first(where: { site in site.pages.contains { $0.id == id } }) else { return nil }
            let others = site.pages.filter { $0.id != id }.map(\.frame)
            return gapX(others, at: to, spacing: 0)
        case .split, .none:
            return nil
        }
    }

    private func gapX(_ frames: [CGRect], at index: Int, spacing: CGFloat) -> CGFloat? {
        guard !frames.isEmpty else { return nil }
        if index <= 0 { return frames[0].minX - max(spacing / 2, 1) }
        if index >= frames.count { return frames[frames.count - 1].maxX + max(spacing / 2, 1) }
        return (frames[index - 1].maxX + frames[index].minX) / 2
    }
}

extension View {
    /// Reports this view's frame in the sites row's space.
    func reportsBarFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BarDragModel.space)) } action: { report($0) }
    }

    /// The lifted look of whatever is being dragged. `backing` is laid under it while lifted, so an
    /// item that has no fill of its own (a page in a capsule, a fading single) does not show what it
    /// passes over. Over a lit split target it shrinks and thins so the target shows through.
    func barDragLift(_ active: Bool, splitting: Bool, translation: CGFloat, backing: Color, cornerRadius: CGFloat,
                     reduceMotion: Bool) -> some View {
        let scale: CGFloat = !active || reduceMotion ? 1 : (splitting ? 0.9 : 1.04)
        return self
            .background {
                if active { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(backing) }
            }
            .scaleEffect(scale)
            .opacity(active ? (splitting ? 0.55 : 0.94) : 1)
            .shadow(color: .black.opacity(active ? 0.2 : 0), radius: active ? 8 : 0, y: active ? 4 : 0)
            .offset(x: active ? translation : 0, y: active ? -2 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: splitting)
    }
}
