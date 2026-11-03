// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: a function nothing calls, and a golangci-lint finding, in the
// package both binaries share.

package shared

import "os"

// Orphan is called by nobody (deadcode).
func Orphan() {}

// Clean drops an error (errcheck). The binaries are built in two
// configurations (cmd/b is pure), so this package is linted twice; the
// finding must be reported once.
func Clean() {
	os.Remove("x")
}
