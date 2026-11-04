// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package full_test

import (
	"testing"

	"example.com/smoke/coverage/full"
)

func TestClamp(t *testing.T) {
	for n, want := range map[int]int{-1: 0, 5: 5, 11: 10} {
		if got := full.Clamp(n, 0, 10); got != want {
			t.Errorf("Clamp(%d, 0, 10) = %d, want %d", n, got, want)
		}
	}
}

func TestBetween(t *testing.T) {
	for n, want := range map[int]bool{-1: false, 5: true, 11: false} {
		if got := full.Between(n, 0, 10); got != want {
			t.Errorf("Between(%d, 0, 10) = %v, want %v", n, got, want)
		}
	}
}
