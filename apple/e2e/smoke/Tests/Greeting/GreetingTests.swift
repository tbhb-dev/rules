// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import Greeting
import XCTest

final class GreetingTests: XCTestCase {
    func testMessageNamesTheGreeted() {
        XCTAssertEqual(Greeting(name: "Bazel").message, "Hello, Bazel!")
    }
}
