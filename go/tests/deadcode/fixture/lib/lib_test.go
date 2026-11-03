// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package lib

import "testing"

func TestOnlyTests(t *testing.T) {
	if OnlyTests() != 2 {
		t.Fatal("OnlyTests")
	}
}
