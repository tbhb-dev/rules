# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `commit_identity` target against a throwaway repository."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

_TRAILER_CASES = """
# Compare the complete combined output and status, both for each commit and
# for the mixed range. Git log visits these linear commits newest first.
subject="$PWD/@@SUBJECT@@"
human='Tony Burns <tony@tonyburns.net>'
summary='The allowed pairs are ALLOWED_PAIRS in @tbhb_rules//lint/private:commit_identity.bzl; use an allowed identity pair and valid agent identity trailers.'
expected_range=
failures=0
count=0
check_output() {
  local from=$1 expected_status=$2 expected=$3 status=0 actual
  actual=$(BUILD_WORKSPACE_DIRECTORY="$repo" "$subject" "$from" HEAD 2>&1) || status=$?
  if [[ "$status" != "$expected_status" || "$actual" != "$expected" ]]; then
    printf 'status: %s (expected %s)\\nactual:\\n%s\\nexpected:\\n%s\\n' "$status" "$expected_status" "$actual" "$expected" >&2
    exit 1
  fi
}
check_commit() {
  local author=$1 committer=$2 message=$3 problems=${4-} sha lines= problem
  commit "$author" "$committer" "$message"
  sha=$(git -C "$repo" rev-parse HEAD)
  count=$((count + 1))
  if [[ -n "$problems" ]]; then
    while IFS= read -r problem; do
      lines+="commit_identity: FAIL: $sha $problem"$'\\n'
    done <<<"$problems"
    check_output HEAD~1 1 "${lines}commit_identity: 1 of 1 commits failed. $summary"
    expected_range="$lines$expected_range"
    failures=$((failures + 1))
  else
    check_output HEAD~1 0 'commit_identity: 1 commits checked'
  fi
}
check_commit "$agent" "$agent" "$valid"
check_commit "$agent" "$agent" change 'missing Generated-by or Assisted-by trailer'
check_commit "$agent" "$agent" $'change\\n\\nGenerated-by: nope' 'Generated-by: nope: must start with literal LLM'
check_commit "$agent" "$agent" $'change\\n\\nAssisted-by: LLM harness=codex;model=m\\nGenerated-by: LLM harness=codex;model=m' 'Generated-by: LLM harness=codex;model=m: Generated-by must come before Assisted-by'
check_commit "$agent" "$agent" "$valid"$'\\nSigned-off-by: H <h@example.invalid>' 'Signed-off-by: H <h@example.invalid>: Signed-off-by and Co-authored-by are forbidden for agent commits'
check_commit "$agent" "$agent" "$valid"$'\\nco-authored-by: H <h@example.invalid>' 'co-authored-by: H <h@example.invalid>: Signed-off-by and Co-authored-by are forbidden for agent commits'
check_commit "$human" "$human" change
check_commit "$human" "$human" $'change\\n\\nGenerated-by: nope\\nSigned-off-by: H <h@example.invalid>'
check_commit "$human" "$agent" change $'author and committer are not an allowed pair: Tony Burns <tony@tonyburns.net> (author) -> tbhb.dev Agent <agent@tonyburns.net> (committer)\\nmissing Generated-by or Assisted-by trailer'
check_commit "$agent" "$human" change $'author and committer are not an allowed pair: tbhb.dev Agent <agent@tonyburns.net> (author) -> Tony Burns <tony@tonyburns.net> (committer)\\nmissing Generated-by or Assisted-by trailer'
check_commit "$agent" "$agent" $'change\\n\\nAssisted-by: LLM harness=codex;model=m'
check_commit "$agent" "$agent" $'change\\n\\nGenerated-by: nope\\nAssisted-by: nope' $'Generated-by: nope: must start with literal LLM\\nAssisted-by: nope: must start with literal LLM'
check_output "$base" 1 "${expected_range}commit_identity: $failures of $count commits failed. $summary"
"""

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
repo="$TEST_TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
# The base commit's identity is not allowed, so a passing scenario also
# shows that the check keeps to the range.
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m base
base=$(git -C "$repo" rev-parse HEAD)
agent='tbhb.dev Agent <agent@tonyburns.net>'
valid=$'change\n\nGenerated-by: LLM harness=codex;model=openai:m'
# commit AUTHOR COMMITTER, each as `Name <email>`.
commit() {{
  local an=${{1% <*}} ae=${{1##*<}} cn=${{2% <*}} ce=${{2##*<}}
  GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=${{ae%>}} GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=${{ce%>}} \\
    git -C "$repo" commit -q --allow-empty -m "${{3-$valid}}"
}}
case {scenario} in
  allowed)
    commit "$agent" "$agent"
    commit 'Tony Burns <tony@tonyburns.net>' 'Tony Burns <tony@tonyburns.net>'
    commit 'tbhb-dev-renovate[bot] <289255489+tbhb-dev-renovate[bot]@users.noreply.github.com>' 'GitHub <noreply@github.com>'
    ;;
  trailers)
{trailer_cases}
    exit 0
    ;;
  empty) ;;
  noreply_author)
    commit "$agent" "$agent"
    commit 'tbhb-agent <334376894+tbhb-agent@users.noreply.github.com>' "$agent"
    ;;
  wrong_committer)
    commit "$agent" 'GitHub <noreply@github.com>'
    ;;
esac
BUILD_WORKSPACE_DIRECTORY="$repo" "$PWD/{subject}" "$base" HEAD
"""

def _commit_identity_scenario_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            trailer_cases = _TRAILER_CASES.replace("@@SUBJECT@@", ctx.executable.subject.short_path),
            git_dir = path_dir(ctx.attr.git),
            scenario = ctx.attr.scenario,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject, ctx.executable.git])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

commit_identity_scenario_test = rule(
    implementation = _commit_identity_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["allowed", "empty", "noreply_author", "wrong_committer", "trailers"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
