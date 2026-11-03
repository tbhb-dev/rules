// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command smoke compares its arguments with a fixed list.
package main

import (
	"fmt"
	"os"

	"example.com/smoke/lib"
)

func main() {
	fmt.Println(lib.Same(os.Args[1:], []string{"smoke"}))
}
