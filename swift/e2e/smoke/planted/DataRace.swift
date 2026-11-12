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
        let ready = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            ready[index].signal()
            ready[1 - index].wait()
            counter.value += 1
        }
        XCTAssertGreaterThan(counter.value, 0)
    }
}
