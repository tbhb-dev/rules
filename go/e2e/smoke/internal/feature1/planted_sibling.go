// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: a feature imports its sibling.

package feature1

import "example.com/smoke/internal/feature2"

// Both uses the sibling feature.
func Both() string { return feature2.Two() }
