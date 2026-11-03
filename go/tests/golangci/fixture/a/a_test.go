// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package a

import (
	"os"
	"testing"
)

// An internal test with an errcheck finding.
func TestRemove(t *testing.T) {
	os.Remove("missing")
	if testOnly() != 1 {
		t.Fatal("testOnly")
	}
}
