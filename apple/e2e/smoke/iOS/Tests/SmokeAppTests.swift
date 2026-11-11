// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import Greeting
import XCTest

final class SmokeAppTests: XCTestCase {
    func testRunsOnTheSimulator() {
        #if targetEnvironment(simulator)
            XCTAssertEqual(Greeting(name: "iOS").message, "Hello, iOS!")
        #else
            XCTFail("this test must run on the iOS simulator")
        #endif
    }
}
