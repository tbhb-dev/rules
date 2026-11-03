// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package extra is attached to no go-arch-lint component.
package extra

import "example.com/smoke/internal/feature1"

// Extra reaches a feature.
func Extra() string { return feature1.One() }
