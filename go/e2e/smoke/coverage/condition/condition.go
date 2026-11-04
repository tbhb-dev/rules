// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package condition is a planted coverage failure: its tests run every line
// but miss an operand of each of its conditions, one of an && and one of an ||.
package condition

// Weekend reports whether day, 1 for Monday through 7 for Sunday, is
// Saturday or Sunday.
func Weekend(day int) bool {
	return day == 6 || day == 7
}

// InRange reports whether n is 0 through 10.
func InRange(n int) bool {
	return n >= 0 && n <= 10
}
