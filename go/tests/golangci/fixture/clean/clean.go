// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package clean has no findings.
package clean

import "strings"

// Shout upper-cases s.
func Shout(s string) string {
	return strings.ToUpper(s) + "!"
}
