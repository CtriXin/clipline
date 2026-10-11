import XCTest
@testable import Clipline

final class HotZoneTests: XCTestCase {
    func testMiddleIsCentredAndNarrowerThanTheBar() throws {
        let band = NSRect(x: 0, y: 945, width: 1512, height: 37)
        let mid = try XCTUnwrap(HotZone.middle.area(in: band))
        XCTAssertEqual(mid.midX, band.midX, accuracy: 0.5)
        XCTAssertLessThan(mid.width, band.width / 2)
        XCTAssertFalse(NSMouseInRect(NSPoint(x: 40, y: 960), mid, false))   // the Apple menu
        XCTAssertTrue(NSMouseInRect(NSPoint(x: 756, y: 960), mid, false))   // the notch
        XCTAssertEqual(HotZone.whole.area(in: band), band)
        XCTAssertNil(HotZone.off.area(in: band))
    }
}
