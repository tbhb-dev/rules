// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package a holds planted findings for the golangci-lint parity fixture.
package a

import (
	"fmt"
	"os"
	"time"
)

// Logf is a printf wrapper. govet's printf check learns that from a fact
// it exports for this package, and checks callers in other packages.
func Logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format, args...)
}

// Remove drops an error (errcheck).
func Remove(path string) {
	os.Remove(path)
}

// Kept drops an error too, but a nolint directive suppresses it.
func Kept(path string) {
	os.Remove(path) //nolint:errcheck // Planted and suppressed on purpose.
}

func unusedHelper() {} // unused

// Ineffectual assigns a value that is never read (ineffassign).
func Ineffectual() int {
	x := 1
	x = 2
	return x
}

// Nap sleeps for one nanosecond (staticcheck SA1004).
func Nap() {
	time.Sleep(1)
}

// Direct calls fmt.Printf with a bad verb (govet printf, no fact needed).
func Direct(n int) {
	fmt.Printf("%s\n", n)
}

// testOnly is used only by the package's tests.
func testOnly() int { return 1 }
