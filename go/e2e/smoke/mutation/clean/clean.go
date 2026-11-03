// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package clean has tests that kill every gomutants mutant of it.
package clean

// Pass reports whether a score of 0 to 100 passes: 50 and up.
func Pass(score int) bool {
	return score >= 50
}

// Double returns twice n.
func Double(n int) int {
	return n * 2
}
