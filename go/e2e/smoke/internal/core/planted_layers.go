// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: a lower layer imports a feature above it.

package core

import "example.com/smoke/internal/feature1"

// Down reaches a feature.
func Down() string { return feature1.One() }
