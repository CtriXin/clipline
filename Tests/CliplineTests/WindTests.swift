import XCTest
@testable import Clipline

@MainActor
final class WindTests: XCTestCase {
    func testCardsAheadOfARightwardSweepLeanRight() {
        let wind = Line.Wind(x: 300, speed: 900)
        let near = Line.lean(cardX: 400, in: wind)
        let far = Line.lean(cardX: 1100, in: wind)
        XCTAssertLessThan(near, 0)                 // bottom swings right
        XCTAssertLessThan(abs(far), abs(near))     // fades with distance
        XCTAssertEqual(Line.lean(cardX: 100, in: wind), 0)   // behind the hand
    }

    func testLeftwardSweepMirrorsAndCalmIsStill() {
        let left = Line.lean(cardX: 200, in: Line.Wind(x: 300, speed: -900))
        XCTAssertGreaterThan(left, 0)
        XCTAssertEqual(Line.lean(cardX: 400, in: .calm), 0)
        XCTAssertLessThanOrEqual(abs(Line.lean(cardX: 300, in: Line.Wind(x: 300, speed: 99_999))), 13)
    }
}
