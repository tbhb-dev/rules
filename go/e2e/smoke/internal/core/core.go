// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package core sits on platform.
package core

import "example.com/smoke/internal/platform"

// Greeting greets the platform.
func Greeting() string { return "hello " + platform.Name() }
