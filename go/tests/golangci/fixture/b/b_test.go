// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package b_test

import (
	"testing"
	"time"

	"example.com/fixture/b"
)

// An external test package with a staticcheck finding.
func TestReport(t *testing.T) {
	b.Report(1)
	time.Sleep(1)
}
