// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package shared is used by both binaries.
package shared

// Used is called by both binaries.
func Used() string { return "used" }

// OnlyB is called by cmd/b only: deadcode run per binary would call it
// dead in cmd/a, but over both binaries it is live.
func OnlyB() string { return "only b" }
