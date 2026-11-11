# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Exercise the range checker with LF and CRLF command output on every OS."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

_GIT = """#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'rev-parse --verify --quiet '*) exit 0 ;;
  'log --format='*)
    printf '%s\\t%s%s\\n' abc123 'tbhb.dev Agent <agent@tonyburns.net> -> tbhb.dev Agent <agent@tonyburns.net>' "$ENDING"
    ;;
  'log -1 --format=%ae%n%ce abc123')
    printf '%s%s\\n' agent@tonyburns.net "$ENDING" agent@tonyburns.net "$ENDING"
    ;;
  'log -1 --format=%B abc123') printf 'change%s\\n' "$ENDING" ;;
  *) echo "unexpected git arguments: $*" >&2; exit 2 ;;
esac
"""

_TRAILERS = """#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '%s%s\\n' 'Generated-by: nope: must start with literal LLM' "$ENDING" 'Assisted-by: nope: must start with literal LLM' "$ENDING"
exit 1
"""

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export BUILD_WORKSPACE_DIRECTORY="$TEST_TMPDIR"
expected='commit_identity: FAIL: abc123 Generated-by: nope: must start with literal LLM
commit_identity: FAIL: abc123 Assisted-by: nope: must start with literal LLM
commit_identity: 1 of 1 commits failed. The allowed pairs are ALLOWED_PAIRS in @tbhb_rules//lint/private:commit_identity.bzl; use an allowed identity pair and valid agent identity trailers.'
for ENDING in '' $'\\r'; do
  export ENDING
  status=0
  actual=$(bash "$PWD/{subject}" BASE HEAD 2>&1) || status=$?
  if [[ "$status" != 1 || "$actual" != "$expected" ]]; then
    printf 'status: %s (expected 1)\\nactual: %q\\nexpected: %q\\n' "$status" "$actual" "$expected" >&2
    exit 1
  fi
done
"""

def _commit_identity_crlf_test_impl(ctx):
    git = ctx.actions.declare_file(ctx.label.name + "/git")
    ctx.actions.write(git, _GIT, is_executable = True)
    trailers = ctx.actions.declare_file(ctx.label.name + "/trailers")
    ctx.actions.write(trailers, _TRAILERS, is_executable = True)
    allowed = ctx.actions.declare_file(ctx.label.name + "/allowed")
    ctx.actions.write(allowed, "tbhb.dev Agent <agent@tonyburns.net> -> tbhb.dev Agent <agent@tonyburns.net>\n")
    subject = ctx.actions.declare_file(ctx.label.name + "/subject.sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = subject,
        substitutions = {
            "@@ALLOWED@@": allowed.short_path,
            "@@GIT_DIR@@": git.short_path.rpartition("/")[0],
            "@@TRAILERS@@": trailers.short_path,
        },
    )
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(driver, _DRIVER.format(subject = subject.short_path), is_executable = True)
    executable, runfiles = shell_executable(ctx, driver, ctx.runfiles(files = [git, trailers, allowed, subject]))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

commit_identity_crlf_test = rule(
    implementation = _commit_identity_crlf_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "_runner": attr.label(default = "//lint/private:commit_identity.sh.tpl", allow_single_file = True),
    },
)
