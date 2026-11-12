// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import Greeting
import XCTest

final class SmokeAppTests: XCTestCase {
    func testMessageNamesMacOS() {
        XCTAssertEqual(Greeting(name: "macOS").message, "Hello, macOS!")
    }
}
