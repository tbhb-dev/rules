// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package dirty holds planted defects for the proofs.
package dirty

import (
	"fmt"
	"os"

	"github.com/google/go-cmp/cmp"
)

// Remove drops an error (errcheck).
func Remove(path string) {
	os.Remove(path)
}

// Kept drops an error too, under a nolint directive.
func Kept(path string) {
	os.Remove(path) //nolint:errcheck // Planted and suppressed on purpose.
}

// Show passes a cmp.Option where a string verb expects a string (govet).
func Show() {
	fmt.Printf("%d\n", cmp.AllowUnexported())
}

// Dead is called by nothing (deadcode).
func Dead() {}
