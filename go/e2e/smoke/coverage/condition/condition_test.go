// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package condition_test

import (
	"testing"

	"example.com/smoke/coverage/condition"
)

func TestWeekend(t *testing.T) {
	if !condition.Weekend(6) || condition.Weekend(1) {
		t.Error("Weekend is wrong for Saturday and Monday")
	}
}

func TestInRange(t *testing.T) {
	if !condition.InRange(5) || condition.InRange(-1) {
		t.Error("InRange is wrong for 5 and -1")
	}
}
