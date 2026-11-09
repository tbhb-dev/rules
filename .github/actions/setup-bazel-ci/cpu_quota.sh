#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Prints the CPUs a container's cgroup quota allows: the quota divided by
# its period, rounded up, at least 1. Prints nothing, and succeeds, when
# there is no quota, the value isn't a pair of integers, or the quota isn't
# below the host's CPU count.
#
# nproc and Python's os.cpu_count() count the host's CPUs and ignore the
# quota.
#
# python/private/mutmut_report.py (max_children) implements the same rule
# for mutmut. Keep the two in step.
#
# Usage: cpu_quota.sh [CPU_MAX [V1_QUOTA V1_PERIOD]]
#
# CPU_MAX is cgroup v2's cpu.max ("<quota|max> <period>"). Without it (or
# with an empty one), cgroup v1's cpu.cfs_quota_us (-1 for no quota) and
# cpu.cfs_period_us are read.
# The arguments default to the kernel's paths and exist so a test can pass
# fake files.

set -euo pipefail

v2=${1:-/sys/fs/cgroup/cpu.max}
v1_quota=${2:-/sys/fs/cgroup/cpu/cpu.cfs_quota_us}
v1_period=${3:-/sys/fs/cgroup/cpu/cpu.cfs_period_us}

quota=
period=
extra=
if [[ -r $v2 ]]; then
  read -r quota period extra <"$v2" || true
fi
# Exactly two fields: a third means the file is not a cpu.max.
[[ -z $extra ]] || exit 0
# An empty or missing cpu.max leaves no quota, and cgroup v1 gets its turn.
if [[ -z $quota && -r $v1_quota && -r $v1_period ]]; then
  read -r quota <"$v1_quota" || true
  read -r period <"$v1_period" || true
fi

# "max" and -1 fail the integer test too. The length cap keeps the
# arithmetic inside 64 bits.
[[ $quota =~ ^[0-9]{1,15}$ && $period =~ ^[0-9]{1,15}$ ]] || exit 0
((10#$period > 0)) || exit 0

cpus=$(((10#$quota + 10#$period - 1) / 10#$period))
((cpus >= 1)) || cpus=1
# cspell:ignore getconf NPROCESSORS ONLN
host=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
((cpus < host)) || exit 0
echo "$cpus"
