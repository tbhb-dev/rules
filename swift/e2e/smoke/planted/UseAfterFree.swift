// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// A planted defect for the AddressSanitizer proof: the test reads memory
// after freeing it.
import XCTest

final class UseAfterFreeTests: XCTestCase {
    func testReadsFreedMemory() {
        let pointer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        pointer.initialize(to: 1)
        pointer.deallocate()
        XCTAssertEqual(pointer.pointee, 1)
    }
}
