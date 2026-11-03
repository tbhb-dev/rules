// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package weak is a planted mutation-testing failure: its test misses the
// boundary of Pass and never calls Double, but kills every mutant of Neg.
package weak

// Pass reports whether a score of 0 to 100 passes: 50 and up.
func Pass(score int) bool {
	return score >= 50
}

// Double returns twice n.
func Double(n int) int {
	return n * 2
}

// Neg returns n negated.
func Neg(n int) int {
	return -n
}
