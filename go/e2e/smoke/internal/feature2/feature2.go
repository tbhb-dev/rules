// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package feature2 is a feature on core.
package feature2

import "example.com/smoke/internal/core"

// Two is feature two.
func Two() string { return core.Greeting() + " two" }
