// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package fmtfixture is not formatted: the imports are unsorted and
// unwrapped and the body is on the brace line.
package fmtfixture

import ("os"
"fmt")

// Print prints the arguments.
func Print() {  fmt.Println(os.Args)
}
