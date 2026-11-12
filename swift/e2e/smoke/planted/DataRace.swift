// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// A planted defect for the ThreadSanitizer proof: the test increments one
// counter from many threads, with no lock.
import Dispatch
import XCTest

private final class Counter: @unchecked Sendable {
    var value = 0
}

final class DataRaceTests: XCTestCase {
    func testIncrementsFromManyThreads() {
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            counter.value += 1
        }
        XCTAssertGreaterThan(counter.value, 0)
    }
}
