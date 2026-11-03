// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

//go:build ignore

package b

import "os"

// Ignored is excluded by its build constraint, so no linter sees it.
func Ignored() {
	os.Remove("x")
}
