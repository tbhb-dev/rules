// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: only cmd/* may import features, and shared is not cmd.

package shared

import "example.com/smoke/internal/feature1"

// Feature reaches a feature.
func Feature() string { return feature1.One() }
