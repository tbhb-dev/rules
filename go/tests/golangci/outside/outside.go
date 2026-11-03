// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package outside counts with a three-clause loop, which intrange flags
// when the project's Go version is 1.22 or later.
package outside

// Count counts to three.
func Count() int {
	n := 0
	for i := 0; i < 3; i++ {
		n += i
	}
	return n
}
