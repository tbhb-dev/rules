#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

git="$TEST_SRCDIR/$GIT_RLOCATIONPATH"
identity="$TEST_SRCDIR/$IDENTITY_RLOCATIONPATH"
merge_base="$TEST_SRCDIR/$MERGE_BASE_RLOCATIONPATH"
messages="$TEST_SRCDIR/$MESSAGES_RLOCATIONPATH"
repo="$TEST_TMPDIR/repo"
export PATH="${git%/*}:$PATH" BUILD_WORKSPACE_DIRECTORY="$repo" LC_ALL=C
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=

in_repo() { "$git" -C "$repo" "$@"; }

as_agent_on_github() {
  GIT_AUTHOR_NAME='tbhb.dev Agent' GIT_AUTHOR_EMAIL=agent@tonyburns.net \
    GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com in_repo "$@"
}

expect_failure() {
  local expected_status=$1 expected_text=$2 actual_status=0 output
  shift 2
  output=$("$@" 2>&1) || actual_status=$?
  if [[ $actual_status != "$expected_status" || $output != *"$expected_text"* ]]; then
    printf 'Expected status %s and output containing %s, received status %s and output:\n%s\n' \
      "$expected_status" "$expected_text" "$actual_status" "$output" >&2
    exit 1
  fi
}

mkdir "$repo"
in_repo init -q -b main
in_repo config user.name 'Tony Burns'
in_repo config user.email tony@tonyburns.net
in_repo commit -qm 'chore: start the fixture' --allow-empty
stored_base=$(in_repo rev-parse HEAD)
in_repo switch -qc topic
in_repo commit -qm 'fix: check the topic commit' --allow-empty
in_repo switch -qc upstream "$stored_base"
# Both checkers skip merge commits. The non-merge commit brought in by the
# upstream merge supplies the stale range's identity and subject failures.
as_agent_on_github commit -qm 'fixup! upstream change' --allow-empty
upstream=$(in_repo rev-parse HEAD)
in_repo switch -q main
as_agent_on_github merge -q --no-ff -m 'Merge upstream' upstream
merged_main=$(in_repo rev-parse HEAD)
in_repo switch -q topic
as_agent_on_github merge -q --no-ff -m 'Merge main' main
head=$(in_repo rev-parse HEAD)
in_repo switch -q main
in_repo commit -qm 'chore: advance main again' --allow-empty
"$git" clone -q --bare "$repo" "$TEST_TMPDIR/origin"
in_repo remote add origin "$TEST_TMPDIR/origin"
in_repo fetch -q origin

# A pull request workflow checks out a synthetic merge with current main.
in_repo switch -q --detach main
as_agent_on_github merge -q --no-ff -m 'Merge topic for CI' topic

base=$("$merge_base" main "$head")
[[ $base == "$merged_main" ]]
identity_output=$("$identity" "$base" "$head")
messages_output=$("$messages" "$base" "$head")
[[ $identity_output == 'commit_identity: 1 commits checked' ]]
[[ $messages_output == 'commit_messages: 1 commits checked' ]]
expect_failure 1 "commit_identity: FAIL: $upstream author and committer are not an allowed pair" \
  "$identity" "$stored_base" "$head"
expect_failure 1 "commit_messages: FAIL: $upstream fixup!, squash! and amend! subjects must be reworded" \
  "$messages" "$stored_base" "$head"

in_repo update-ref -d refs/remotes/origin/main
fetched_base=$("$merge_base" main "$head")
[[ $fetched_base == "$merged_main" ]]
origin_tip=$(in_repo rev-parse refs/remotes/origin/main)
main_tip=$(in_repo rev-parse main)
[[ $origin_tip == "$main_tip" ]]
expect_failure 2 'usage: pr_merge_base BASE_REF HEAD' "$merge_base" main
expect_failure 1 'run this target with bazel run' env -u BUILD_WORKSPACE_DIRECTORY "$merge_base" main "$head"
expect_failure 128 "couldn't find remote ref refs/heads/missing" "$merge_base" missing "$head"
expect_failure 128 'Not a valid object name missing' "$merge_base" main missing
