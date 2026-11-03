// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command app reports whether its arguments are a b.
package main

import (
	"fmt"
	"os"

	"example.com/quickstart/pkg/thing"
)

func main() {
	fmt.Println(thing.Same(os.Args[1:], []string{"a", "b"}))
}
