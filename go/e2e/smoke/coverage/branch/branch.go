// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package branch is a planted coverage failure: its tests run every line
// but never reach the zero branch of Sign.
package branch

// Sign returns -1, 0 or 1 for a negative, zero or positive n.
func Sign(n int) int {
	if n < 0 {
		return -1
	}
	if n == 0 {
		return 0
	}
	return 1
}
