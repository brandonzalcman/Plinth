import Foundation
import CoreGraphics
import Testing
import PlinthModel
@testable import PlinthBarUI

@Suite struct PinDropTests {
    let a = SiteID(), b = SiteID(), c = SiteID()
    let folder = UUID()

    /// Tiles 32 wide with 8 between: a at 0, folder at 40, b at 80, c at 120.
    func slots() -> [PinDropSlot] {
        [PinDropSlot(target: .pin(a), frame: CGRect(x: 0, y: 10, width: 32, height: 32)),
         PinDropSlot(target: .folder(folder), frame: CGRect(x: 40, y: 10, width: 32, height: 32)),
         PinDropSlot(target: .pin(b), frame: CGRect(x: 80, y: 10, width: 32, height: 32)),
         PinDropSlot(target: .pin(c), frame: CGRect(x: 120, y: 10, width: 32, height: 32))]
    }

    @Test func theMiddleOfAPinIsATarget() {
        #expect(PinDrop.target(at: CGPoint(x: 96, y: 26), in: slots(), dragging: a) == .pin(b))
    }

    @Test func theMiddleOfAFolderIsATarget() {
        #expect(PinDrop.target(at: CGPoint(x: 56, y: 26), in: slots(), dragging: a) == .folder(folder))
    }

    @Test func passingBetweenOrOverTheEdgeOfTilesPicksNothing() {
        #expect(PinDrop.target(at: CGPoint(x: 76, y: 26), in: slots(), dragging: a) == nil)      // the gap
        #expect(PinDrop.target(at: CGPoint(x: 82, y: 26), in: slots(), dragging: a) == nil)      // b's edge
        #expect(PinDrop.target(at: CGPoint(x: 96, y: 90), in: slots(), dragging: a) == nil)      // far below
    }

    @Test func theDraggedPinIsNeverItsOwnTarget() {
        #expect(PinDrop.target(at: CGPoint(x: 16, y: 26), in: slots(), dragging: a) == nil)
        #expect(PinDrop.target(at: CGPoint(x: 16, y: 26), in: slots(), dragging: b) == .pin(a))
    }

    @Test func aTileWithNoSizeYetIsSkipped() {
        let s = [PinDropSlot(target: .pin(b), frame: .zero)]
        #expect(PinDrop.target(at: .zero, in: s, dragging: a) == nil)
    }

    @Test func droppingMapsToTheRightAction() {
        #expect(PinDrop.action(dragging: a, onto: .pin(b)) == .groupPins(a, onto: b))
        #expect(PinDrop.action(dragging: a, onto: .folder(folder)) == .movePinToFolder(a, folder: folder))
    }

    @Test func aTargetIsOfferedOnlyAfterTheDwell() {
        var d = PinDropDwell()
        d.observe(.pin(b), at: 10)
        #expect(d.armed(at: 10.1) == nil)
        #expect(d.armed(at: 10 + PinDrop.dwell) == .pin(b))
        // Staying over the same tile does not restart the wait; moving to another one does.
        d.observe(.pin(b), at: 11)
        #expect(d.armed(at: 11) == .pin(b))
        d.observe(.pin(c), at: 12)
        #expect(d.armed(at: 12.1) == nil)
        #expect(d.armed(at: 12.4) == .pin(c))
        d.observe(nil, at: 13)
        #expect(d.armed(at: 14) == nil)
    }
}
