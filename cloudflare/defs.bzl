# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_cloudflare."""

load(
    "//private:worker.bzl",
    _worker_bundle = "worker_bundle",
    _worker_deploy = "worker_deploy",
    _worker_types_test = "worker_types_test",
)

worker_bundle = _worker_bundle
worker_deploy = _worker_deploy
worker_types_test = _worker_types_test
