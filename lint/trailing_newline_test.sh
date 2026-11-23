#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
checker=${TRAILING_NEWLINE_CHECKER:-${TEST_SRCDIR:?}/${CHECKER_RLOCATIONPATH:?}}
if [[ -n ${GIT_RLOCATIONPATH:-} ]]; then
  git_tool=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH}
  export PATH="${git_tool%/*}:$PATH"
fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEMPLATE_DIR=''
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/trailing-newline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

git init -q
commit() {
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -qm "$1"
}
run_check() {
  BUILD_WORKSPACE_DIRECTORY="$scratch" "$checker" "$1" HEAD
}

printf 'original\n' >modified.txt
printf 'no newline' >deleted.txt
printf 'no newline' >unchanged.txt
commit base
base=$(git rev-parse HEAD)

printf 'changed\n' >modified.txt
printf 'new\n' >added.txt
: >empty.txt
printf '%08191d\0data' 0 >binary.txt
rm deleted.txt
for path in \
  lint/gitleaks/base.toml \
  lint/gitleaks/upstream.toml \
  nested/.gitleaks-rules.toml \
  nested/testdata/fixture.txt \
  nested/mutants/result.txt \
  nested/diagram.d2.svg \
  nested/diagram.d2.png \
  nested/diagram.d2.sha256 \
  nested/structurizr-context.svg \
  nested/structurizr-context.png \
  nested/workspace.json \
  nested/worker-configuration.d.ts \
  .vale/Google/style.yml \
  .vale/write-good/style.yml \
  .vale/proselint/style.yml \
  .vale/ai-tells-custom/style.yml \
  .bazel-cache/output.txt \
  bazel-output/output.txt \
  tmp/scratch.txt \
  .worktrees/checkout/file.txt; do
  mkdir -p "${path%/*}"
  printf 'excluded' >"$path"
done
ln -s unchanged.txt link
commit passing
run_check "$base"

passing=$(git rev-parse HEAD)
printf 'changed again' >modified.txt
printf 'missing newline' >'new file.txt'
printf '%08192d\0' 0 >late-nul.txt
printf 'missing newline' >nested/workspace.json.bak
commit failing
printf 'fixed in the worktree\n' >modified.txt

status=0
output=$(run_check "$passing" 2>&1) || status=$?
printf '%s\n' "$output"
[[ $status == 1 ]] || exit 1
[[ $output == *"modified.txt': missing trailing newline"* ]] || exit 1
[[ $output == *"new file.txt': missing trailing newline"* ]] || exit 1
[[ $output == *"late-nul.txt': missing trailing newline"* ]] || exit 1
[[ $output == *"nested/workspace.json.bak': missing trailing newline"* ]] || exit 1

status=0
output=$(run_check missing-revision 2>&1) || status=$?
if [[ $status != 2 ]]; then
  printf 'Expected exit 2 for a missing revision, got %s\n%s\n' "$status" "$output" >&2
  exit 1
fi
