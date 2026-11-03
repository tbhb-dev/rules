// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package weak_test

import (
	"testing"

	"example.com/smoke/mutation/weak"
)

func TestPass(t *testing.T) {
	if !weak.Pass(80) || weak.Pass(10) {
		t.Error("Pass is wrong away from the boundary")
	}
}

func TestNeg(t *testing.T) {
	if got := weak.Neg(3); got != -3 {
		t.Errorf("Neg(3) = %d, want -3", got)
	}
}
