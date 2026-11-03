// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command a uses feature1 and the shared package.
package main

import (
	"fmt"

	"example.com/smoke/internal/feature1"
	"example.com/smoke/internal/shared"
)

func main() {
	fmt.Println(feature1.One(), shared.Used())
}
