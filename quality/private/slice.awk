# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# awk -f slice.awk UNIT_PATHS CHANGES: print the entries of the change set
# CHANGES (mutation_changes' format, one file per line) whose path is in
# UNIT_PATHS (one JSON-escaped path per line), as a change set without its
# base. Fails on anything else in CHANGES.

# An empty UNIT_PATHS still leaves CHANGES to parse.
FILENAME == ARGV[1] { unit[$0] = 1; next }
FNR == 1 { if ($0 != "{") bad(); next }
/^  "version": 1,$/ { version = 1; next }
/^  "base": "[0-9a-f]*",$/ { next }
/^  "files": \{/ { files = 1; if ($0 ~ /\}$/) closed = 1; next }
/^    "/ {
  if (!files) bad()
  line = $0
  sub(/,$/, "", line)
  key = substr(line, 6)
  sub(/": .*$/, "", key)
  if (key in unit) kept[++n] = substr(line, 5)
  next
}
/^  \}$/ { closed = 1; next }
/^\}$/ { done = 1; next }
{ bad() }
function bad() {
  printf "slice.awk: %s:%d: not a change set line: %s\n", FILENAME, FNR, $0 > "/dev/stderr"
  failed = 1
  exit 1
}
END {
  if (failed) exit 1
  if (!version || !closed || !done) {
    print "slice.awk: " FILENAME ": not a complete version 1 change set" > "/dev/stderr"
    exit 1
  }
  printf "{\n  \"version\": 1,\n  \"files\": {"
  for (i = 1; i <= n; i++) printf "%s\n    %s", (i > 1 ? "," : ""), kept[i]
  printf "%s}\n}\n", (n ? "\n  " : "")
}
