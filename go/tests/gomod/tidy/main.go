// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command fixture imports one module from outside the standard library.
package main

import (
	"fmt"

	"github.com/google/go-cmp/cmp"
)

func main() {
	fmt.Println(cmp.Diff(1, 2))
}
