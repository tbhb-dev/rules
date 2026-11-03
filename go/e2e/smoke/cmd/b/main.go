// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command b uses feature2, the shared package (OnlyB too) and lib.
package main

import (
	"fmt"
	"os"

	"example.com/smoke/internal/feature2"
	"example.com/smoke/internal/shared"
	"example.com/smoke/lib"
)

func main() {
	fmt.Println(feature2.Two(), shared.Used(), shared.OnlyB(), lib.Same(os.Args[1:], nil))
}
