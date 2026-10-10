import XCTest
@testable import Clipline

final class LayoutTests: XCTestCase {
    let width: CGFloat = 1512

    func testLineThatFitsIsCentredAndDoesNotSlide() {
        XCTAssertEqual(Layout.maxScroll(count: 3, width: width), 0)
        let mid = Layout.x(index: 1, count: 3, width: width, scroll: 500)
        XCTAssertEqual(mid, width / 2, accuracy: 0.5)
    }

    func testLongLineStartsAfterTabsAndSlides() {
        let count = 20
        let limit = Layout.maxScroll(count: count, width: width)
        XCTAssertGreaterThan(limit, 0)
        let first = Layout.x(index: 0, count: count, width: width)
        XCTAssertEqual(first, Layout.tabsReserve + Layout.cardWidth / 2, accuracy: 0.5)
        XCTAssertFalse(Layout.isOffLine(x: first, width: width))
        // Slid one card along, the first one is put away and the second takes its place.
        let slid = Layout.x(index: 0, count: count, width: width, scroll: Layout.spacing)
        XCTAssertTrue(Layout.isOffLine(x: slid, width: width))
        XCTAssertEqual(Layout.x(index: 1, count: count, width: width, scroll: Layout.spacing), first, accuracy: 0.5)
        // At the far end, the last card sits inside the line.
        let last = Layout.x(index: count - 1, count: count, width: width, scroll: limit)
        XCTAssertFalse(Layout.isOffLine(x: last, width: width))
    }
}
