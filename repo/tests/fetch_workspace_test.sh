#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore endgroup

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/fetch-workspace
mkdir -p "$scratch/bin" "$scratch/workspace"
cat >"$scratch/bin/bazelisk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == "$FAILING_COMMAND" ]]; then
  printf '%s\n' "$BAZEL_ERROR" >&2
  exit 7
fi
if [[ $1 == mod ]]; then
  echo '{}'
fi
MOCK
chmod +x "$scratch/bin/bazelisk"
export PATH="$scratch/bin:$PATH" TARGETS=@default BUDGET=0 WORKSPACES=workspace
export FAILING_COMMAND=mod BAZEL_ERROR='ERROR: must be invoked from within a workspace'
cd "$scratch"

check_failure() {
  local status=0
  bash "$script" >stdout 2>stderr || status=$?
  if [[ $status != 1 ]]; then
    printf 'Expected exit status 1, got %s\n' "$status" >&2
    cat stdout stderr >&2
    exit 1
  fi
}

check_failure
[[ ! -s stdout ]]
grep -qxF '::group::Bazel workspace diagnostic' stderr
grep -qxF "workspace: $PWD/workspace" stderr
grep -qxF "pwd: $PWD/workspace" stderr
grep -qxF 'MODULE.bazel: missing' stderr
grep -qxF 'REPO.bazel: missing' stderr
grep -qxF 'Bazel command: none (workspace check failed before Bazel ran)' stderr
grep -qxF '::endgroup::' stderr
annotation=$(grep '^::error::' stderr)
[[ $annotation == "::error::no MODULE.bazel in $PWD/workspace: the checkout is empty, stale or in the wrong directory" ]]

touch workspace/MODULE.bazel workspace/REPO.bazel
for command in mod query fetch; do
  FAILING_COMMAND=$command check_failure
  grep -qxF 'MODULE.bazel: present' stderr
  grep -qxF 'REPO.bazel: present' stderr
  grep -q ' REPO\.bazel$' stderr
  grep -qxF "Bazel command: $command" stderr
  annotation=$(grep '^::error::' stderr)
  [[ $annotation == "::error::Bazel $command could not find a workspace from $PWD/workspace (MODULE.bazel exists)" ]]
done

BAZEL_ERROR='ERROR: some other failure' check_failure
[[ ! -s stderr ]]
output=$(cat stdout)
[[ $output == $'ERROR: some other failure\n::error::ERROR: some other failure' ]]
