#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Tests for tools/interim/install.sh, which installs the prek git hook shims.
# prek is stubbed: the tests check what install.sh asks of it, not prek itself.

bats_require_minimum_version 1.5.0

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/install.sh"
	# Isolate git from the user's and the harness's configuration. Harnesses
	# inject GIT_AUTHOR_*, GIT_COMMITTER_* and GIT_CONFIG_* into agent shells.
	local names v
	names=$(compgen -e)
	for v in $names; do
		[[ $v == GIT_* ]] && unset "$v"
	done
	export HOME="${BATS_TEST_TMPDIR}/home"
	export GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/global.gitconfig"
	mkdir -p "$HOME"
	: >"$GIT_CONFIG_GLOBAL"
	# Each run of install.sh gets a PATH holding only what it needs, so a real
	# prek or mise on the developer's machine never leaks in.
	STUBS="${BATS_TEST_TMPDIR}/stubs"
	CALLS="${BATS_TEST_TMPDIR}/calls"
	mkdir -p "$STUBS"
	local tool target
	for tool in env git bash; do
		target=$(command -v "$tool")
		ln -s "$target" "${STUBS}/${tool}"
	done
	export CALLS
	REPO="${BATS_TEST_TMPDIR}/repo"
	git init -q "$REPO"
	cd "$REPO" || return
}

# stub <name>: a stand-in that appends its name and arguments to $CALLS.
stub() {
	# shellcheck disable=SC2016 # $* and $CALLS expand when the stub runs
	printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n' "$1" >"${STUBS}/$1"
	chmod +x "${STUBS}/$1"
}

EXPECTED="install --hook-type pre-commit --hook-type prepare-commit-msg --hook-type commit-msg --hook-type post-commit --hook-type pre-push"

@test "installs every hook stage through prek" {
	stub prek
	run env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$output" = "install.sh: installed prek hooks" ]
	run cat "$CALLS"
	[ "$output" = "prek ${EXPECTED}" ]
}

@test "is idempotent" {
	stub prek
	run env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	run env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	run cat "$CALLS"
	[ "${lines[0]}" = "prek ${EXPECTED}" ]
	[ "${lines[1]}" = "prek ${EXPECTED}" ]
}

@test "falls back to mise exec when prek is not on PATH" {
	stub mise
	run env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	run cat "$CALLS"
	[ "$output" = "mise exec -- prek ${EXPECTED}" ]
}

@test "prefers prek over mise" {
	stub prek
	stub mise
	run env PATH="$STUBS" "$SCRIPT"
	run cat "$CALLS"
	[ "$output" = "prek ${EXPECTED}" ]
}

@test "fails clearly when neither prek nor mise exists" {
	run --separate-stderr env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ "$stderr" = "install.sh: error: prek not found; run it through 'uv run' (prek is in the uv dev group)" ]
}

@test "warns and stops when a local core.hooksPath is set" {
	stub prek
	git config --local core.hooksPath custom/hooks
	run --separate-stderr env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$stderr" = "install.sh: warning: core.hooksPath is custom/hooks; not installing prek hooks" ]
	[ ! -e "$CALLS" ]
	run git config --local core.hooksPath
	[ "$output" = "custom/hooks" ]
}

@test "warns when core.hooksPath is set globally and leaves it alone" {
	stub prek
	git config --global core.hooksPath /global/hooks
	run --separate-stderr env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$stderr" = "install.sh: warning: core.hooksPath is /global/hooks; not installing prek hooks" ]
	[ ! -e "$CALLS" ]
	run git config --global core.hooksPath
	[ "$output" = "/global/hooks" ]
}

@test "does not set core.hooksPath itself" {
	stub prek
	run env PATH="$STUBS" "$SCRIPT"
	run git config --get core.hooksPath
	[ "$status" -eq 1 ]
}

@test "reports a prek failure" {
	printf '#!/bin/sh\nexit 3\n' >"${STUBS}/prek"
	chmod +x "${STUBS}/prek"
	run env PATH="$STUBS" "$SCRIPT"
	[ "$status" -eq 3 ]
}
