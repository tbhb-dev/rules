// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package b

// Exported has no doc comment (revive).
func Exported() {}

// Teh comment has a misspelling: recieve (misspell).
func Spell() {}

// always passes the same value, so its parameter is pointless (unparam).
func always(n int) int {
	return n + 1
}

// Callers calls always twice with the same argument.
func Callers() int {
	return always(1) + always(1)
}

// Single uses an if-else chain on one value (gocritic ifElseChain).
func Single(n int) string {
	if n == 1 {
		return "one"
	} else if n == 2 {
		return "two"
	} else if n == 3 {
		return "three"
	}
	return "many"
}
