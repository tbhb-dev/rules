// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package branch_test

import (
	"testing"

	"example.com/smoke/coverage/branch"
)

func TestSign(t *testing.T) {
	if branch.Sign(-5) != -1 || branch.Sign(7) != 1 {
		t.Error("Sign is wrong away from zero")
	}
}
