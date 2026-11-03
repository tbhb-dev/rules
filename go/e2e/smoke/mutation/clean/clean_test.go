// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package clean_test

import (
	"testing"

	"example.com/smoke/mutation/clean"
)

func TestPass(t *testing.T) {
	for score, want := range map[int]bool{49: false, 50: true, 80: true} {
		if got := clean.Pass(score); got != want {
			t.Errorf("Pass(%d) = %v, want %v", score, got, want)
		}
	}
}

func TestDouble(t *testing.T) {
	if got := clean.Double(3); got != 6 {
		t.Errorf("Double(3) = %d, want 6", got)
	}
}
