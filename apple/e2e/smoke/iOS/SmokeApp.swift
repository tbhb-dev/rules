// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import Greeting
import SwiftUI

@main
struct SmokeApp: App {
    var body: some Scene {
        WindowGroup {
            Text(Greeting(name: "iOS").message)
        }
    }
}
