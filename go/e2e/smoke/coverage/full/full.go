// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package full has tests that reach both outcomes of every condition.
package full

// Clamp limits n to lo through hi.
func Clamp(n, lo, hi int) int {
	if n < lo {
		return lo
	}
	if n > hi {
		return hi
	}
	return n
}

// Between reports whether n is lo through hi.
func Between(n, lo, hi int) bool {
	return n >= lo && n <= hi
}
