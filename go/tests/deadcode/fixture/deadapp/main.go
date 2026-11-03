// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command deadapp uses dead.Live only.
package main

import (
	"fmt"

	"example.com/deadcode/dead"
)

func main() {
	fmt.Println(dead.Live())
}
