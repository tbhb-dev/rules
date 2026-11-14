# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`gate_output_test`: a mutation gate that must pass and print given lines."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

_SCRIPT = """#!/usr/bin/env bash
set -uo pipefail
gate="$PWD/{gate}"
work="$TEST_TMPDIR/gate_output"
mkdir -p "$work"
summary="$work/summary.md"
: >"$summary"
status=0
GITHUB_STEP_SUMMARY=$summary "$gate" >"$work/out.log" 2>&1 || status=$?
if ((status != 0)); then
  echo "gate_output_test: FAIL: the gate exited $status" >&2
  cat "$work/out.log" >&2
  exit 1
fi
for line in {lines}; do
  if ! grep -qxF -- "$line" "$work/out.log"; then
    echo "gate_output_test: FAIL: output lacks '$line'" >&2
    cat "$work/out.log" >&2
    exit 1
  fi
done
for line in {summary_lines}; do
  if ! grep -qxF -- "$line" "$summary"; then
    echo "gate_output_test: FAIL: summary lacks '$line'" >&2
    cat "$summary" >&2
    exit 1
  fi
done
# The gate must also pass with the variable unset.
env -u GITHUB_STEP_SUMMARY "$gate" >/dev/null 2>&1 || {{
  echo "gate_output_test: FAIL: the gate fails without GITHUB_STEP_SUMMARY" >&2
  exit 1
}}
"""

def _impl(ctx):
    if not ctx.attr.lines:
        fail("lines must not be empty")
    gate = ctx.attr.gate[DefaultInfo].files_to_run.executable
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = _SCRIPT.format(
            gate = gate.short_path,
            lines = " ".join([shell.quote(line) for line in ctx.attr.lines]),
            summary_lines = " ".join([shell.quote(line) for line in ctx.attr.summary_lines]),
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [gate]).merge(ctx.attr.gate[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gate_output_test = rule(
    implementation = _impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Passes when `gate` passes and its output holds each of `lines`.

Runs the gate with GITHUB_STEP_SUMMARY set to a scratch file that must hold
each of `summary_lines`, then once more with it unset.""",
    attrs = SHELL_ATTRS | {
        "gate": attr.label(mandatory = True, executable = True, cfg = "target"),
        "lines": attr.string_list(doc = "Whole lines the gate's output must hold."),
        "summary_lines": attr.string_list(doc = "Whole lines the summary file must hold."),
    },
)
