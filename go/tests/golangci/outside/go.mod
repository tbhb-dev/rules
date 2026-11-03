// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// A planted go.mod the lint action is never given. Its old Go version turns
// intrange off, so if the action read it from the source tree, the finding
// in outside.go would disappear.
module example.com/outside

go 1.21
