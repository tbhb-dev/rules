// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package b

import "os"

// Drop drops an error; the config's exclusion rule hides errcheck here.
func Drop(path string) {
	os.Remove(path)
}
