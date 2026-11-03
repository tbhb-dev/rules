// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package lib has a function the binary uses and one only its test uses.
package lib

// Used is called by the binary.
func Used() int { return 1 }

// OnlyTests is called by the test only.
func OnlyTests() int { return 2 }
