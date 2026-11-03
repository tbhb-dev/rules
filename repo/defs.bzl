# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for repository plumbing rules."""

load("//repo/private:repo_files.bzl", _repo_files = "repo_files")
load("//repo/private:repo_layout.bzl", _repo_layout_test = "repo_layout_test")

repo_files = _repo_files
repo_layout_test = _repo_layout_test
