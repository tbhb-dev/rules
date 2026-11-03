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

// Show prints a string with %d (govet printf). Seeing that cmp.Diff
// returns a string takes go-cmp's types.
func Show() {
	fmt.Printf("%d\n", cmp.Diff(1, 2))
}
