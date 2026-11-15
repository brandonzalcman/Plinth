import SwiftUI
import AppKit
import PlinthModel

// MARK: - Deciding a drop (no UI, so it can be tested)

/// Where a dragged pin can be dropped to group it.
enum PinDropTarget: Hashable, Sendable {
    /// Another pin: the two become a new folder.
    case pin(SiteID)
    /// A folder tile: the pin joins it.
    case folder(UUID)
}

/// A pin or folder tile on the bar and where it is.
struct PinDropSlot: Equatable {
    var target: PinDropTarget
    var frame: CGRect
}

enum PinDrop {
    /// How long the pointer rests on a tile before it is offered as the target.
    static let dwell: TimeInterval = 0.32
    /// This far above or below the tile, the pointer no longer counts as over it.
    static let verticalSlack: CGFloat = 8

    /// The tile the pointer is resting over, if any: its middle part (so passing between tiles never
    /// picks one), never the dragged pin itself.
    static func target(at p: CGPoint, in slots: [PinDropSlot], dragging: SiteID) -> PinDropTarget? {
        for slot in slots where slot.target != .pin(dragging) {
            let f = slot.frame
            guard f.width > 0, f.height > 0 else { continue }
            let inset = max(4, f.width * 0.2)
            if p.x > f.minX + inset, p.x < f.maxX - inset, p.y > f.minY - verticalSlack, p.y < f.maxY + verticalSlack {
                return slot.target
            }
        }
        return nil
    }

    /// The action for letting go of `dragged` on `target`.
    static func action(dragging dragged: SiteID, onto target: PinDropTarget) -> BarAction {
        switch target {
        case .pin(let other): return .groupPins(dragged, onto: other)
        case .folder(let id): return .movePinToFolder(dragged, folder: id)
        }
    }
}

/// Offers a target only after the pointer has stayed over it for `PinDrop.dwell`.
struct PinDropDwell: Equatable {
    private(set) var candidate: PinDropTarget?
    private var since: TimeInterval = 0

    /// Notes what is under the pointer now.
    mutating func observe(_ target: PinDropTarget?, at time: TimeInterval) {
        guard target != candidate else { return }
        candidate = target
        since = time
    }

    /// The target, once it has been under the pointer long enough.
    func armed(at time: TimeInterval) -> PinDropTarget? {
        guard let candidate, time - since >= PinDrop.dwell else { return nil }
        return candidate
    }
}

// MARK: - The drag

/// Dragging a pin tile on the bar, to group it. Like the sites row, this is done by hand with a
/// `DragGesture`: the row never rearranges; the dragged tile follows the pointer, and after the
/// pointer rests on another pin or a folder, that tile lights up. Letting go there groups; letting
/// go anywhere else changes nothing.
@MainActor @Observable
final class PinDragModel {
    /// The named coordinate space of the whole bar row, which holds the pin tiles.
    nonisolated static let space = "plinth.bar.row"

    private(set) var subject: SiteID?
    private(set) var translation: CGFloat = 0
    /// The tile lit up as the drop target.
    private(set) var target: PinDropTarget?

    @ObservationIgnored var frames: [PinDropTarget: CGRect] = [:]
    /// The pin and folder tiles in bar order, set by the bar on every render.
    @ObservationIgnored var order: [PinDropTarget] = []
    @ObservationIgnored var onDrop: (BarAction) -> Void = { _ in }
    @ObservationIgnored var dropAnimation: Animation?
    @ObservationIgnored private var start: CGPoint = .zero
    @ObservationIgnored private var dwell = PinDropDwell()
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var lastMove = ContinuousClock.now
    @ObservationIgnored private var lastEnded: ContinuousClock.Instant?

    var isDragging: Bool { subject != nil }
    func isDragging(pin: SiteID) -> Bool { subject == pin }

    /// True while dragging and just after, so the button under the pointer does not also take the
    /// release as a click.
    var suppressesClick: Bool {
        if subject != nil { return true }
        guard let lastEnded else { return false }
        return ContinuousClock.now - lastEnded < .milliseconds(250)
    }

    func gesture(for pin: SiteID) -> some Gesture {
        DragGesture(minimumDistance: BarDragModel.minimumDistance, coordinateSpace: .named(Self.space))
            .onChanged { [weak self] value in
                guard let self else { return }
                if self.subject == nil { self.begin(pin, at: value.startLocation) }
                guard self.subject == pin else { return }
                self.move(to: value.location)
            }
            .onEnded { [weak self] _ in
                guard let self, self.subject == pin else { return }
                self.finish()
            }
    }

    private func begin(_ pin: SiteID, at point: CGPoint) {
        subject = pin
        start = point
        translation = 0
        cancelled = false
        dwell = PinDropDwell()
        lastMove = .now
        startWatch()
    }

    private func move(to point: CGPoint) {
        lastMove = .now
        guard !cancelled, let subject else { return }
        translation = point.x - start.x
        let slots = order.compactMap { t in frames[t].map { PinDropSlot(target: t, frame: $0) } }
        let over = PinDrop.target(at: point, in: slots, dragging: subject)
        let before = dwell.candidate
        dwell.observe(over, at: Self.clock())
        if over == nil { target = nil }
        if dwell.candidate != before {
            target = nil
            dwellTask?.cancel()
            guard over != nil else { return }
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(PinDrop.dwell))
                guard !Task.isCancelled, let self, !self.cancelled else { return }
                self.target = self.dwell.armed(at: Self.clock())
            }
        }
    }

    private static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Escape puts the tile back; a drag whose gesture vanished is cleared once the button is up.
    private func startWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.subject != nil else { return }
                if !self.cancelled, CGEventSource.keyState(.combinedSessionState, key: 53) { self.cancelDrag() }
                if NSEvent.pressedMouseButtons & 1 == 0, ContinuousClock.now - self.lastMove > .milliseconds(1500) {
                    self.target = nil
                    self.finish()
                    return
                }
            }
        }
    }

    private func cancelDrag() {
        cancelled = true
        dwellTask?.cancel()
        withAnimation(dropAnimation) { translation = 0; target = nil }
    }

    private func finish() {
        let action = subject.flatMap { s in target.map { PinDrop.action(dragging: s, onto: $0) } }
        lastEnded = .now
        withAnimation(dropAnimation) {
            dwellTask?.cancel(); dwellTask = nil
            watch?.cancel(); watch = nil
            subject = nil
            translation = 0
            target = nil
            cancelled = false
            dwell = PinDropDwell()
            if let action { onDrop(action) }
        }
    }
}

extension View {
    /// Reports this tile's frame in the bar row's space, for drops.
    func reportsPinFrame(_ target: PinDropTarget, into drag: PinDragModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PinDragModel.space)) } action: { drag.frames[target] = $0 }
    }
}
