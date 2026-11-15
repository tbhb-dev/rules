#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Run the plan's actual jq selection and filters, without the GitHub API.
# Accept a workflow path so the same test can check an earlier revision.
# Run with bash repo/tests/ci_plan_test.sh [workflow], with jq and python3 on PATH.
set -euo pipefail
workflow=${1:-${TEST_SRCDIR:-.}/${WORKFLOW_RLOCATIONPATH:-.github/workflows/ci.yml}}
dir=$(mktemp -d "${TMPDIR:-/tmp}/ci-plan-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

workspaces=$(awk '
  /^          WORKSPACES: \|$/ { found = 1; next }
  found && /^        run: \|$/ { exit }
  found { sub(/^            /, ""); print }
' "$workflow")
plan=$(awk '
  /^          selected="/ { found = 1 }
  found && /^          echo "workspaces=/ { exit }
  found { sub(/^          /, ""); print }
' "$workflow")
[[ -n $workspaces && -n $plan ]] || {
  echo 'FAIL: missing workspace selection in the workflow' >&2
  exit 1
}
# shellcheck disable=SC2016
plan=$'files=$1\n'"$plan"
# shellcheck disable=SC2016
plan+=$'\n''printf "{\"selected\":%s,\"matrix\":%s,\"apple\":%s,\"swift\":%s}\n" "$selected" "$matrix" "$apple" "${swift:-false}"'

# Check the wiring as well as the selection, so a missing output cannot skip a job.
job_block() {
  awk -v job="$1" '
    $0 == "  " job ":" { found = 1; next }
    found && /^  [^ ]/ { exit }
    found { print }
  ' "$workflow"
}

# Evaluate each OS expression for both events before combining it with the
# plan's nonempty workspace matrix. Python's operators match this expression.
for job in cache-warm bazel; do
  os=$(job_block "$job" | awk '
    /^        os: / { sub(/^        os: /, ""); print; found = 1; next }
    found && /^          / { print; next }
    found { exit }
  ')
  python3 - "$job" "$os" <<'PY'
import json
import sys

job, expression = sys.argv[1:]
expression = " ".join(expression.split())
failures = 0
for event in ("pull_request", "push"):
    if expression.startswith("${{"):
        source = expression[3:-2].strip()
        source = source.replace("github.event_name", "event")
        source = source.replace("&&", "and").replace("||", "or")
        os_list = eval(source, {"__builtins__": {}, "fromJSON": json.loads, "event": event})
    else:
        os_list = [os.strip() for os in expression.strip("[]").split(",")]
    expected = ["ubuntu-26.04", "ubuntu-26.04-arm"]
    if event == "push":
        expected += ["macos-26", "windows-2025"]
    print(f"{job} {event}: {json.dumps(os_list)}", flush=True)
    if os_list != expected:
        print(f"FAIL: {job} {event}: expected {json.dumps(expected)}", file=sys.stderr)
        failures += 1
sys.exit(bool(failures))
PY
done

# Windows and macOS run on pushes and schedules, not on pull requests, so
# no job tolerates a failure: a failed row must fail `conclusion`.
if job_block bazel | grep -q '^    continue-on-error:'; then
  echo "FAIL: bazel must not set continue-on-error" >&2
  exit 1
fi

# The Xcode jobs must succeed without running steps on pull requests, while
# pushes retain the workspace selection and failure-only log uploads.
python3 - "$workflow" <<'PY'
import re
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text()
failures = 0
for job in ("apple", "swift"):
    block = re.search(rf"^  {job}:\n(.*?)(?=^  \S|\Z)", workflow, re.M | re.S)[1]
    runner = re.search(r"^    runs-on: (.+)$", block, re.M)[1]
    steps = re.split(r"^      - ", block, flags=re.M)[1:]
    conditions = []
    for step in steps:
        condition = re.search(r"^        if: (.+)$", step, re.M)
        conditions.append(condition[1] if condition else "True")

    for event in ("pull_request", "push"):
        def evaluate(expression, selected="true", failed=False):
            source = expression.removeprefix("${{").removesuffix("}}").strip()
            source = source.replace("github.event_name", "event")
            source = source.replace(f"env.RUN_{job.upper()}", "selected")
            source = source.replace("failure()", "failed")
            source = source.replace("&&", "and").replace("||", "or")
            return eval(source, {"__builtins__": {}}, {
                "event": event, "selected": selected, "failed": failed,
            })

        actual_runner = evaluate(runner) if runner.startswith("${{") else runner
        expected_runner = "ubuntu-26.04" if event == "pull_request" else "xcode-27"
        actual_steps = [evaluate(condition) for condition in conditions]
        print(f"{job} {event}: runs-on={actual_runner} steps={actual_steps}", flush=True)
        if actual_runner != expected_runner:
            print(f"FAIL: {job} {event}: expected runs-on={expected_runner}", file=sys.stderr)
            failures += 1
        for selected in ("false", "true"):
            for failed in (False, True):
                actual = [evaluate(condition, selected, failed) for condition in conditions]
                run = event == "push" and selected == "true"
                expected = [run] * 4 + [run and failed]
                if actual != expected:
                    print(f"FAIL: {job} {event} selected={selected} failure={failed}: "
                          f"steps={actual}, expected {expected}", file=sys.stderr)
                    failures += 1
sys.exit(bool(failures))
PY

plan_job=$(job_block plan)
outputs=$(awk '
  /^    outputs:$/ { found = 1; next }
  found && /^    [^ ]/ { exit }
  found { print }
' <<<"$plan_job")
output_writes=$(awk '
  /^        id: plan$/ { found = 1; next }
  found && /^      - / { exit }
  found && /^          (echo|printf) .*>>[[:space:]]*"?[$][{]?GITHUB_OUTPUT[}]?"?$/ { print }
' <<<"$plan_job")
conclusion=$(job_block conclusion)
for platform in apple swift; do
  grep -qxF "      $platform: \${{ steps.plan.outputs.$platform }}" <<<"$outputs" || {
    echo "FAIL: plan outputs must declare $platform from steps.plan.outputs.$platform" >&2
    exit 1
  }
  grep -qE '(^|[^[:alnum:]_]|\\n)'"$platform=" <<<"$output_writes" || {
    echo "FAIL: plan step must write $platform= to GITHUB_OUTPUT" >&2
    exit 1
  }
  job_env=$(job_block "$platform" | awk '
    /^    env:$/ { found = 1; next }
    found && /^    [^ ]/ { exit }
    found { print }
  ')
  run=$(tr '[:lower:]' '[:upper:]' <<<"$platform")
  grep -qxF "      RUN_$run: \${{ needs.plan.outputs.$platform }}" <<<"$job_env" || {
    echo "FAIL: $platform job must set RUN_$run from needs.plan.outputs.$platform" >&2
    exit 1
  }
  grep -qE "^    needs: \[([^]]*, )?$platform(,|])" <<<"$conclusion" || {
    echo "FAIL: conclusion needs must include $platform" >&2
    exit 1
  }
done

failures=0
for path in apple/e2e/smoke/BUILD.bazel README.md e2e/smoke/README.md swift/defs.bzl swift/e2e/smoke/BUILD.bazel swift/private/simulator/tbhb_rules_swift_simulator/test_simulator_runtime.py; do
  printf '%s\n' "$path" >"$dir/changed"
  result=$(WORKSPACES="$workspaces" bash -euo pipefail -c "$plan" -- "$dir/changed" 2>&1) || {
    echo "FAIL: $path: $result" >&2
    exit 1
  }
  summary=$(jq -cr '"matrix=\(.matrix) apple=\(.apple) swift=\(.swift)"' <<<"$result")
  echo "$path: $summary"
  case $path in
  apple/e2e/smoke/BUILD.bazel)
    assertion='.matrix == [{id: "root", dir: "."}] and .apple == true and .swift == false'
    ;;
  README.md)
    # A root file must retain every workspace in the shared matrix.
    assertion='.matrix == (.selected | map(select(.id != "apple-smoke" and .id != "swift" and .id != "swift-smoke"))) and (.matrix | length > 1)'
    ;;
  e2e/smoke/README.md)
    assertion='.matrix == [{id: "smoke", dir: "e2e/smoke"}] and .apple == false'
    ;;
  swift/defs.bzl)
    assertion='.matrix == [{id: "root", dir: "."}] and .apple == false and .swift == true'
    ;;
  swift/e2e/smoke/BUILD.bazel | swift/private/simulator/tbhb_rules_swift_simulator/test_simulator_runtime.py)
    assertion='.matrix == [{id: "root", dir: "."}] and .apple == false and .swift == true'
    ;;
  *) assertion='true' ;;
  esac
  if ! jq -e "(.matrix | length > 0) and ($assertion)" <<<"$result" >/dev/null; then
    echo "FAIL: $path: unexpected matrix or smoke selection" >&2
    failures=$((failures + 1))
  fi
done
((failures == 0)) || exit 1
echo 'PASS: Apple and Swift changes keep a root matrix and select their smoke; root changes keep the shared matrix; all matrices are nonempty'
