// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package fmtfixture is formatted.
package fmtfixture

import (
	"fmt"
	"os"
)

// Print prints the arguments.
func Print() {
	fmt.Println(os.Args)
}
