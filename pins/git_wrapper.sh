#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the pinned dugite-native Git from wherever its archive was unpacked.
#
# dugite-native is not relocatable by itself: the GitHub Desktop dugite
# library points Git at the files beside it through the environment before it
# runs it (lib/git-environment.ts, setupEnvironment in desktop/dugite). Run
# bare, `git --exec-path` prints `//libexec/git-core`, so no helper is found
# and every HTTPS remote fails with "remote-https is not a git command".
#
# pins/extensions.bzl installs this file as bin/git-wrapper in each unpacked
# archive. It finds the archive by following its own symlinks (Bazel's
# runfiles and bazel_env's shims are links to it), sets what dugite sets, and
# runs the real bin/git.

set -eu

self=$0
while [ -h "$self" ]; do
  link=$(readlink -- "$self")
  case $link in
  /*) self=$link ;;
  *) self=$(dirname -- "$self")/$link ;;
  esac
done
root=$(cd -- "$(dirname -- "$self")/.." && pwd -P)

# Always set. Git exports its own GIT_EXEC_PATH to hooks and aliases, so a
# value in the environment may belong to another Git, whose helpers this one
# must not run. PREFIX is a common name that other programs set for their own
# use; Git on Linux reads it as its install prefix.
GIT_EXEC_PATH=$root/libexec/git-core
export GIT_EXEC_PATH
kernel=$(uname -s)
if [ "$kernel" = Linux ]; then
  PREFIX=$root
  export PREFIX
fi

# Set only when the caller has not chosen a value, empty included: callers
# set GIT_TEMPLATE_DIR= to get a repository with no sample hooks.
# GIT_CONFIG_NOSYSTEM=1 still turns the system config off.
if [ -z "${GIT_CONFIG_SYSTEM+set}" ] && [ -f "$root/etc/gitconfig" ]; then
  GIT_CONFIG_SYSTEM=$root/etc/gitconfig
  export GIT_CONFIG_SYSTEM
fi
if [ -z "${GIT_TEMPLATE_DIR+set}" ] && [ -d "$root/share/git-core/templates" ]; then
  GIT_TEMPLATE_DIR=$root/share/git-core/templates
  export GIT_TEMPLATE_DIR
fi
# The Linux build has no system certificate store of its own; the archive
# ships a bundle.
if [ -z "${GIT_SSL_CAINFO:-}" ] && [ -f "$root/ssl/cacert.pem" ]; then
  GIT_SSL_CAINFO=$root/ssl/cacert.pem
  export GIT_SSL_CAINFO
fi

exec "$root/bin/git" "$@"
