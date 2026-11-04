// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package called calls a vulnerable function of golang.org/x/text v0.3.6:
// language.ParseAcceptLanguage (GO-2021-0113 and GO-2022-1059).
package called

import "golang.org/x/text/language"

// Accepted returns the languages of an Accept-Language header.
func Accepted(header string) ([]language.Tag, error) {
	tags, _, err := language.ParseAcceptLanguage(header)
	return tags, err
}
