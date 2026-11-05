# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Unit tests for the validation the rules run when loaded.

The rules are macros, so their fail() runs in the loading phase, where an
analysis test can't catch it. The checks are functions, tested here; the
macros fail with exactly the messages they return.
"""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//private:storybook.bzl", "FRAMEWORKS", "RENDERERS", "framework_error", "node_modules_error", "node_modules_path", "tree_path")

def _test_frameworks(env):
    for framework in ["astro", "html", "react", "web-components"]:
        env.expect.that_bool(framework_error(framework) == None).equals(True)
    env.expect.that_collection(FRAMEWORKS.keys()).contains_exactly(RENDERERS.keys())

def _test_bad_framework(env):
    env.expect.that_str(framework_error("vue")).equals(
        "framework: \"vue\" isn't one of astro, html, react, web-components",
    )

def _test_main_repo_tree(env):
    env.expect.that_bool(node_modules_error(Label("@@//:node_modules")) == None).equals(True)
    env.expect.that_str(node_modules_path(Label("@@//:node_modules"))).equals("node_modules")
    env.expect.that_str(node_modules_path(Label("@@//sb:node_modules"))).equals("sb/node_modules")

def _test_other_repo(env):
    error = node_modules_error(Label("@@other+//:node_modules"))
    env.expect.that_str(error).equals(
        "node_modules: @@other+//:node_modules is from repository @other+; pass the consumer's own npm_link_all_packages target",
    )

def _test_not_a_tree(env):
    error = node_modules_error(Label("@@//:node_modules/react"))
    env.expect.that_str(error).contains("isn't an npm_link_all_packages target")

def _test_tree_path(env):
    env.expect.that_collection(tree_path("sb/src/a.ts", "sb")).contains_exactly(["src/a.ts", None]).in_order()
    env.expect.that_collection(tree_path("src/a.ts", "")).contains_exactly(["src/a.ts", None]).in_order()
    env.expect.that_collection(tree_path("other/a.ts", "sb")).contains_exactly(
        [None, "srcs: other/a.ts isn't under this package, sb"],
    ).in_order()
    env.expect.that_collection(tree_path("sbx/a.ts", "sb")).contains_exactly(
        [None, "srcs: sbx/a.ts isn't under this package, sb"],
    ).in_order()

def rules_test_suite(name):
    test_suite(
        name = name,
        basic_tests = [
            _test_bad_framework,
            _test_frameworks,
            _test_main_repo_tree,
            _test_not_a_tree,
            _test_other_repo,
            _test_tree_path,
        ],
    )
