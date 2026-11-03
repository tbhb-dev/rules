// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package b imports package a, for the cross-package findings.
package b

import "example.com/fixture/a"

// Report calls a's printf wrapper with a bad verb. govet sees it only
// through the fact package a exports.
func Report(n int) {
	a.Logf("%s\n", n)
}
