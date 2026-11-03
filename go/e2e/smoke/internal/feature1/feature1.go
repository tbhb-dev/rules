// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package feature1 is a feature on core.
package feature1

import "example.com/smoke/internal/core"

// One is feature one.
func One() string { return core.Greeting() + " one" }
