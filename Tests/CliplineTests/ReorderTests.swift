import XCTest
@testable import Clipline

@MainActor
final class ReorderTests: XCTestCase {
    func testMovingACardAndTidyingUp() throws {
        let line = Line()
        let urls = ["one", "two", "three"].map { Clips.storeText($0) }
        let ids = urls.compactMap { line.hang($0, quietly: true) }
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(line.isTidy)

        line.moveCard(ids[2], to: 0)
        XCTAssertEqual(line.items.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertFalse(line.isTidy)

        line.tidy()
        XCTAssertEqual(line.items.map(\.id), ids)
        XCTAssertTrue(line.isTidy)
        urls.forEach(Clips.forget)
    }
}
