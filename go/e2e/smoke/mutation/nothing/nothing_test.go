// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package nothing_test

import (
	"testing"

	"example.com/smoke/mutation/nothing"
)

func TestGreeting(t *testing.T) {
	if nothing.Greeting != "hello" {
		t.Errorf("Greeting = %q", nothing.Greeting)
	}
}
