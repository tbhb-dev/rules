// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

/// A greeting for one name.
public struct Greeting: Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public var message: String {
        if name.isEmpty {
            return "Hello, world!"
        }
        return "Hello, \(name)!"
    }
}
