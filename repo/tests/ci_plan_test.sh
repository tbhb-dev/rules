#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Run the plan with a local stand-in for the GitHub API.
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
  /^          files="/ { found = 1 }
  found && /^          echo "workspaces=/ { exit }
  found { sub(/^          /, ""); print }
' "$workflow")
[[ -n $workspaces && -n $plan ]] || {
  echo 'FAIL: missing workspace selection in the workflow' >&2
  exit 1
}
# shellcheck disable=SC2016
plan+=$'\n''printf "{\"selected\":%s,\"matrix\":%s,\"apple\":%s,\"swift\":%s}\n" "$selected" "$matrix" "$apple" "${swift:-false}"'

gh() {
  if [[ -n $CHANGED_FILES && $# == 5 && $1 == api && $2 == --paginate && $4 == --jq ]]; then
    case "${EVENT:?}:$3" in
    pull_request:repos/test/rules/pulls/123/files)
      jq -r "$5" "$CHANGED_FILES"
      return
      ;;
    merge_group:repos/test/rules/compare/queue-base...queue-head)
      # The compare endpoint includes files on its first page only.
      jq '{files: .}, {}' "$CHANGED_FILES" | jq -r "$5"
      return
      ;;
    esac
  fi
  echo "FAIL: unexpected GitHub API call: $*" >&2
  return 1
}
export -f gh

run_plan() {
  EVENT="$1" CHANGED_FILES="${2:-}" PR=123 BASE_SHA=queue-base HEAD_SHA=queue-head WORKSPACES="$workspaces" \
    RUNNER_TEMP="$dir" GITHUB_REPOSITORY=test/rules bash -euo pipefail -c "$plan"
}

# Check the wiring as well as the selection, so a missing output cannot skip a job.
job_block() {
  awk -v job="$1" '
    $0 == "  " job ":" { found = 1; next }
    found && /^  [^ ]/ { exit }
    found { print }
  ' "$workflow"
}

# Evaluate the cache OS expression for both events. The Bazel job uses the
# plan's expanded matrix, checked below.
bazel_job=$(job_block bazel)
grep -qxF "        include: \${{ fromJSON(needs.plan.outputs.workspaces) }}" <<<"$bazel_job"
job=cache-warm
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

# A failed matrix row must fail `conclusion` on any event.
if job_block bazel | grep -q '^    continue-on-error:'; then
  echo "FAIL: bazel must not set continue-on-error" >&2
  exit 1
fi

# The Xcode jobs must succeed without steps on pull requests and merge groups, while
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

    for event in ("pull_request", "merge_group", "push"):
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
        expected_runner = "xcode-27" if event == "push" else "ubuntu-26.04"
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
# Pull requests run Linux amd64 only. The merge queue runs each workspace's
# platforms, the four by default, as pushes do.
pr_platforms='["ubuntu-26.04"]'
for path in apple/e2e/smoke/BUILD.bazel README.md e2e/smoke/README.md swift/defs.bzl swift/e2e/smoke/BUILD.bazel swift/private/simulator/tbhb_rules_swift_simulator/test_simulator_runtime.py diagrams/structurizr/defs.bzl; do
  jq -n --arg path "$path" '[{filename: $path}]' >"$dir/files.json"
  result=$(run_plan pull_request "$dir/files.json")
  queue_result=$(run_plan merge_group "$dir/files.json")
  # The queue selects the same workspaces and keeps every platform; the pull
  # request keeps only the Linux amd64 legs of the queue's matrix.
  # shellcheck disable=SC2016 # jq expands workspaces.
  jq -e -n --argjson pr "$result" --argjson queue "$queue_result" --argjson workspaces "$workspaces" '
    ($pr | del(.matrix)) == ($queue | del(.matrix))
    and $pr.matrix == ($queue.matrix | map(select(.os == "ubuntu-26.04")))
    and ($queue.matrix | group_by(.workspace.id) | all(
      .[0].workspace.id as $id
      | (map(.os) | sort) == ([$workspaces[] | select(.id == $id)][0].os
          // ["ubuntu-26.04", "ubuntu-26.04-arm", "macos-26", "windows-2025"] | sort)))
  ' >/dev/null || {
    echo "FAIL: $path: merge_group must select the pull request's workspaces on every platform" >&2
    exit 1
  }
  echo "PASS: merge_group runs every platform of the pull request's workspaces for $path"
  case $path in
  apple/e2e/smoke/BUILD.bazel)
    assertion='(.matrix | map(.workspace) | unique) == [{id: "root", dir: "."}] and .apple == true and .swift == false'
    ;;
  README.md)
    # A root file must retain every workspace in the shared matrix.
    full_result=$result
    full_queue_result=$queue_result
    # shellcheck disable=SC2016 # jq expands workspaces.
    assertion='(.selected | map(.id)) == ($workspaces | map(.id)) and .apple and .swift
      and (.matrix | map(.workspace.id) | unique) == ($workspaces | map(.id) - ["apple-smoke", "swift", "swift-smoke"] | sort)'
    ;;
  e2e/smoke/README.md)
    assertion='(.matrix | length) == 1 and (.matrix | map(.workspace) | unique) == [{id: "smoke", dir: "e2e/smoke"}] and .apple == false and .swift == false'
    ;;
  swift/defs.bzl)
    assertion='(.matrix | map(.workspace) | unique) == [{id: "root", dir: "."}] and .apple == false and .swift == true'
    ;;
  swift/e2e/smoke/BUILD.bazel | swift/private/simulator/tbhb_rules_swift_simulator/test_simulator_runtime.py)
    assertion='(.matrix | map(.workspace) | unique) == [{id: "root", dir: "."}] and .apple == false and .swift == true'
    ;;
  diagrams/structurizr/defs.bzl)
    assertion='(.matrix | map(.workspace) | unique) == [{id: "structurizr", dir: "diagrams/structurizr"}]'
    ;;
  *) assertion='true' ;;
  esac
  # cspell:ignore argjson
  if ! jq -e --argjson platforms "$pr_platforms" --argjson workspaces "$workspaces" "(.matrix | length > 0) and ($assertion)
    and (.matrix | group_by(.workspace.id) | all(map(.os) | sort == \$platforms))" <<<"$result" >/dev/null; then
    echo "FAIL: $path: unexpected matrix or smoke selection" >&2
    failures=$((failures + 1))
  fi
done
((failures == 0)) || exit 1
echo 'PASS: Apple and Swift changes keep a root matrix and select their smoke; root changes keep the shared matrix; all matrices are nonempty; pull requests run Linux amd64 only; Structurizr excludes Windows'

for event in pull_request merge_group; do
  limit=3000
  expected=$full_result
  if [[ $event == merge_group ]]; then
    limit=300
    expected=$full_queue_result
  fi
  for count in 0 "$limit"; do
    jq -n --argjson count "$count" '[range($count) | {filename: "e2e/smoke/file-\(.)"}]' >"$dir/files.json"
    result=$(run_plan "$event" "$dir/files.json")
    [[ $result == "$expected" ]] || {
      echo "FAIL: $event with $count changed files did not select the full matrix" >&2
      exit 1
    }
    echo "PASS: $event with $count changed files selects the full matrix"
  done
done

result=$(run_plan push)
platforms='["macos-26", "ubuntu-26.04", "ubuntu-26.04-arm", "windows-2025"]'
jq -e --argjson workspaces "$workspaces" --argjson platforms "$platforms" '
  (.selected | map(.id)) == ($workspaces | map(.id)) and .apple and .swift
  and (.matrix | map(.workspace.id) | unique) ==
    ($workspaces | map(.id) - ["apple-smoke", "swift", "swift-smoke"] | sort)
  and ([.matrix[] | select(.workspace.id == "structurizr" and .os == "windows-2025")] | length == 0)
  and (.matrix | map(.os) | unique == $platforms)
' <<<"$result" >/dev/null
echo "PASS: push selects all workspaces and uses $platforms"
