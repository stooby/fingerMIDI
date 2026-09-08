//
//  NumericInputTests.swift
//  fingerMIDI-Tests
//
//  First unit tests: value clamping used by the numeric parameter fields.
//

import XCTest
@testable import fingerMIDI

final class NumericInputTests: XCTestCase {

    func testClampWithinRangeIsUnchanged() {
        XCTAssertEqual(clampToRange(0.5, min: 0, max: 1), 0.5)
    }

    func testClampBelowMinReturnsMin() {
        XCTAssertEqual(clampToRange(-3, min: 0, max: 1), 0)
    }

    func testClampAboveMaxReturnsMax() {
        // 200 is above max (127), so this actually exercises the upper clamp.
        XCTAssertEqual(clampToRange(200, min: 0, max: 127), 127)
    }

    func testClampAtBoundariesIsInclusive() {
        XCTAssertEqual(clampToRange(0, min: 0, max: 1), 0)   // exactly min
        XCTAssertEqual(clampToRange(1, min: 0, max: 1), 1)   // exactly max
    }
}
