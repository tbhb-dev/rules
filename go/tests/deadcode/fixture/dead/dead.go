// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package dead has a function nothing calls.
package dead

// Live is called by deadapp.
func Live() int { return 1 }

// Dead is called by nothing.
func Dead() int { return 2 }
