// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package thing compares values with go-cmp.
package thing

import "github.com/google/go-cmp/cmp"

// Same reports whether a and b are equal.
func Same(a, b []string) bool {
	return cmp.Equal(a, b)
}
