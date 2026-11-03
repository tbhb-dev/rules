// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package lib compares values with go-cmp, a module from outside the
// standard library.
package lib

import "github.com/google/go-cmp/cmp"

// Same reports whether a and b are equal.
func Same(a, b []string) bool {
	return cmp.Equal(a, b)
}

// Diff describes how a and b differ; only tests use it.
func Diff(a, b []string) string {
	return cmp.Diff(a, b)
}
