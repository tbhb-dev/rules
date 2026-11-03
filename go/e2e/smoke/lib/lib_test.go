// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package lib_test

import (
	"testing"

	"example.com/smoke/lib"
)

func TestSame(t *testing.T) {
	if !lib.Same([]string{"a"}, []string{"a"}) {
		t.Error(lib.Diff([]string{"a"}, []string{"a"}))
	}
}
