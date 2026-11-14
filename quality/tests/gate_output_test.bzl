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

_SUMMARY_ERROR_SCRIPT = """#!/usr/bin/env bash
set -uo pipefail
gate="$PWD/{gate}"
work="$TEST_TMPDIR/gate_summary_error"
mkdir -p "$work"
status=0
: >"$work/err.log"
if (({close_stderr})); then
  # Nothing can be written to stderr, the warning included.
  GITHUB_STEP_SUMMARY="$work/missing/summary.md" "$gate" >"$work/out.log" 2>&- || status=$?
else
  GITHUB_STEP_SUMMARY="$work/missing/summary.md" "$gate" >"$work/out.log" 2>"$work/err.log" || status=$?
fi
if ((status != {status})); then
  echo "gate_summary_error_test: FAIL: the gate exited $status, not {status}" >&2
  cat "$work/out.log" "$work/err.log" >&2
  exit 1
fi
for line in {lines}; do
  if ! grep -qxF -- "$line" "$work/out.log"; then
    echo "gate_summary_error_test: FAIL: stdout lacks '$line'" >&2
    cat "$work/out.log" >&2
    exit 1
  fi
done
if ! (({close_stderr})); then
  for line in "mutation_gate: could not write to GITHUB_STEP_SUMMARY" {err_lines}; do
    if ! grep -qxF -- "$line" "$work/err.log"; then
      echo "gate_summary_error_test: FAIL: stderr lacks '$line'" >&2
      cat "$work/err.log" >&2
      exit 1
    fi
  done
fi
"""

def _summary_error_impl(ctx):
    gate = ctx.attr.gate[DefaultInfo].files_to_run.executable
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = _SUMMARY_ERROR_SCRIPT.format(
            gate = gate.short_path,
            status = ctx.attr.status,
            close_stderr = 1 if ctx.attr.close_stderr else 0,
            err_lines = " ".join([shell.quote(line) for line in ctx.attr.err_lines]),
            lines = " ".join([shell.quote(line) for line in ctx.attr.lines]),
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [gate]).merge(ctx.attr.gate[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gate_summary_error_test = rule(
    implementation = _summary_error_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Passes when `gate`, run with `GITHUB_STEP_SUMMARY` in a missing directory,
still exits with `status`, prints each of `lines` to stdout and notes the
failed write on stderr, with each of `err_lines`. With `close_stderr` the gate
runs with stderr closed and nothing is read from it.""",
    attrs = SHELL_ATTRS | {
        "close_stderr": attr.bool(default = False, doc = "Run the gate with stderr closed."),
        "err_lines": attr.string_list(doc = "More whole lines the gate's stderr must hold."),
        "gate": attr.label(mandatory = True, executable = True, cfg = "target"),
        "lines": attr.string_list(mandatory = True, doc = "Whole lines the gate's stdout must hold."),
        "status": attr.int(mandatory = True, values = [0, 1], doc = "The exit status the gate must keep."),
    },
)

_ERROR_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
gate="$PWD/{gate}"
work="$TEST_TMPDIR/gate_command_error"
if command -v cygpath >/dev/null 2>&1; then work=$(cygpath -u "$work"); fi
mkdir -p "$work/bin"
real=$(command -v {tool})
export GATE_REAL_TOOL="$real" GATE_FAULT_PATTERN={pattern} GATE_FAULT_OPTION={option}
export GATE_FAULT_MARKER="$work/injected" GATE_FAULT_STATUS={error_status}
printf '%s\\n' {shim_lines} >"$work/bin/{tool}"
chmod +x "$work/bin/{tool}"
printf 'PATH="%s/bin:$PATH"\\n' "$work" >"$work/env.sh"
export BASH_ENV="$work/env.sh"
status=0
PATH="$work/bin:$PATH" "$gate" >"$work/out.log" 2>"$work/err.log" || status=$?
if [[ ! -f $GATE_FAULT_MARKER ]]; then
  echo "gate_command_error_test: FAIL: fault was not injected" >&2
  exit 1
fi
if ((status != 1)); then
  echo "gate_command_error_test: FAIL: the gate exited $status, not 1" >&2
  cat "$work/out.log" "$work/err.log" >&2
  exit 1
fi
if ! grep -qF -- {message} "$work/err.log"; then
  echo "gate_command_error_test: FAIL: stderr lacks the report and step" >&2
  cat "$work/err.log" >&2
  exit 1
fi
"""

_ERROR_SHIM = [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    'for arg in "" "$@"; do',
    '  if [[ $arg == "$GATE_FAULT_PATTERN" && ( -z $GATE_FAULT_OPTION || $1 == "$GATE_FAULT_OPTION" ) ]]; then',
    '    : >"$GATE_FAULT_MARKER"',
    # An error may follow valid output; the gate must reject that output too.
    '    "$GATE_REAL_TOOL" "$@" || true',
    '    exit "$GATE_FAULT_STATUS"',
    "  fi",
    "done",
    'exec "$GATE_REAL_TOOL" "$@"',
]

def _command_error_impl(ctx):
    gate = ctx.attr.gate[DefaultInfo].files_to_run.executable
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = _ERROR_SCRIPT.format(
            gate = gate.short_path,
            tool = ctx.attr.tool,
            pattern = shell.quote(ctx.attr.pattern),
            option = shell.quote(ctx.attr.option),
            error_status = ctx.attr.error_status,
            shim_lines = " ".join([shell.quote(line) for line in _ERROR_SHIM]),
            message = shell.quote("{}: {} failed".format(ctx.attr.report, ctx.attr.step)),
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [gate]).merge(ctx.attr.gate[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gate_command_error_test = rule(
    implementation = _command_error_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = "Injects a command error; requires exit 1 and the report and step on stderr.",
    attrs = SHELL_ATTRS | {
        "error_status": attr.int(default = 2),
        "gate": attr.label(mandatory = True, executable = True, cfg = "target"),
        "option": attr.string(doc = "If set, also require this first option."),
        "pattern": attr.string(doc = "Fail on this exact argument; empty fails every call."),
        "report": attr.string(mandatory = True),
        "step": attr.string(mandatory = True),
        "tool": attr.string(default = "grep", values = ["grep", "cut", "sort", "paste"]),
    },
)
