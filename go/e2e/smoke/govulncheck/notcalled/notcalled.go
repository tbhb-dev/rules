// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package notcalled imports golang.org/x/text/language v0.3.6, which has
// vulnerable functions, and calls none of them.
package notcalled

import "golang.org/x/text/language"

// Default returns the language to use when a request names none.
func Default() language.Tag {
	return language.English
}
