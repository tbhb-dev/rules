// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: the leaf layer imports a layer above it.

package platform

import "example.com/smoke/internal/core"

// Up reaches up to core.
func Up() string { return core.Greeting() }
