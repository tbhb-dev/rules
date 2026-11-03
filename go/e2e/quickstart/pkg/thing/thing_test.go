// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package thing

import "testing"

func TestSame(t *testing.T) {
	if !Same([]string{"a"}, []string{"a"}) {
		t.Error("equal slices differ")
	}
}
