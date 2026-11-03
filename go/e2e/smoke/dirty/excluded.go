// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package dirty

import "os"

// Drop drops an error, in a file the config excludes from errcheck.
func Drop(path string) {
	os.Remove(path)
}
