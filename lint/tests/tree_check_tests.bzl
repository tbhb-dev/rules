# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests for tree_check_test and the lint macros."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//lint:defs.bzl", "bats_test", "gitleaks_test", "rumdl_test", "tombi_test", "tree_check_test")

_ROOT = "lint/tests/testdata/root"

def _subject(name, **kwargs):
    attrs = dict(
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    attrs.update(kwargs)
    util.helper_target(tree_check_test, name = name, **attrs)

def _test_layout(name):
    _subject(
        name = name + "_subject",
        config = "testdata/root/cfg.toml",
        strip_prefix = _ROOT,
        tool_args = ["--config", "{config}", "."],
    )
    analysis_test(name = name, impl = _test_layout_impl, target = name + "_subject")

def _test_layout_impl(env, target):
    manifest = env.expect.that_target(target).action_generating(
        "{}/{}.manifest".format(target.label.package, target.label.name),
    )
    manifest.content().equals("a.txt\ncfg.toml\n")
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@GIT_ROOT@@": "",
        "@@MIN_FILES@@": "1",
        "@@OUTPUT_GUARD@@": "''",
        "@@STRIP_PREFIX@@": "'{}'".format(_ROOT),
        "@@TOOL_ARGS@@": "'--config' 'cfg.toml' '.'",
    })

def _test_unstripped_paths_are_repository_relative(name):
    _subject(name = name + "_subject", min_files = 3, git_root = True)
    analysis_test(name = name, impl = _test_unstripped_paths_impl, target = name + "_subject")

def _test_unstripped_paths_impl(env, target):
    manifest = env.expect.that_target(target).action_generating(
        "{}/{}.manifest".format(target.label.package, target.label.name),
    )
    manifest.content().equals(_ROOT + "/a.txt\n")
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@GIT_ROOT@@": "1",
        "@@MIN_FILES@@": "3",
        "@@STRIP_PREFIX@@": "''",
    })

def _test_file_outside_prefix_fails(name):
    _subject(
        name = name + "_subject",
        srcs = ["testdata/root/a.txt", "testdata/outside.txt"],
        strip_prefix = _ROOT,
    )
    analysis_test(name = name, impl = _expect_failure("is not under strip_prefix"), target = name + "_subject", expect_failure = True)

def _test_prefix_must_match_whole_directory(name):
    # "lint/tests/testdata/ro" is a string prefix of the file's path but not
    # a directory of it.
    _subject(name = name + "_subject", strip_prefix = "lint/tests/testdata/ro")
    analysis_test(name = name, impl = _expect_failure("is not under strip_prefix"), target = name + "_subject", expect_failure = True)

def _test_config_placeholder_needs_config(name):
    _subject(name = name + "_subject", tool_args = ["{config}"])
    analysis_test(name = name, impl = _expect_failure("no config is set"), target = name + "_subject", expect_failure = True)

def _test_cache_path_cannot_escape(name):
    _subject(name = name + "_subject", cache_files = {"testdata/root/cfg.toml": "a/../../x"})
    analysis_test(name = name, impl = _expect_failure("is not a relative path inside the cache"), target = name + "_subject", expect_failure = True)

def _test_cache_path_cannot_be_absolute(name):
    _subject(name = name + "_subject", cache_files = {"testdata/root/cfg.toml": "/x"})
    analysis_test(name = name, impl = _expect_failure("is not a relative path inside the cache"), target = name + "_subject", expect_failure = True)

def _expect_failure(text):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*{}*".format(text)))

    return impl

def _test_cache_files_and_env(name):
    _subject(
        name = name + "_subject",
        cache_files = {"testdata/root/cfg.toml": "tool/schema.json"},
        env = {"A": "b"},
    )
    analysis_test(name = name, impl = _test_cache_files_and_env_impl, target = name + "_subject")

def _test_cache_files_and_env_impl(env, target):
    cache = env.expect.that_target(target).action_generating(
        "{}/{}.cache_manifest".format(target.label.package, target.label.name),
    )
    cache.content().equals(_ROOT + "/cfg.toml\ttool/schema.json\n")
    env.expect.that_target(target).runfiles().contains("_main/{}/cfg.toml".format(_ROOT))
    env.expect.that_target(target).provider(RunEnvironmentInfo).environment().contains_exactly({"A": "b"})

def _test_gitleaks_guard(name):
    util.helper_target(
        gitleaks_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_gitleaks_guard_impl, target = name + "_subject")

def _test_gitleaks_guard_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@OUTPUT_GUARD@@": "'scanned ~[1-9][0-9]* bytes'",
        "@@TOOL_ARGS@@": "'dir' '--no-banner' '--redact' '--verbose' '.'",
    })

def _test_tombi_schemas(name):
    util.helper_target(
        tombi_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        schemas = {"https://example.com/s/a.json": "testdata/root/cfg.toml"},
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_tombi_schemas_impl, target = name + "_subject.lint")

def _test_tombi_schemas_impl(env, target):
    cache = env.expect.that_target(target).action_generating(
        "{}/{}.cache_manifest".format(target.label.package, target.label.name),
    )
    cache.content().equals(_ROOT + "/cfg.toml\ttombi/https/example.com/s/a.json\n")

def _test_bats_uses_pinned_git(name):
    util.helper_target(
        bats_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tests = ["a.bats"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_bats_uses_pinned_git_impl, target = name + "_subject")

def _test_bats_uses_pinned_git_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@TOOL_ARGS@@": "'a.bats'",
    })

    # The hub's canonical name depends on the module's name in the graph
    # (`+tools+...` here, `tbhb_rules++tools+...` in a consumer).
    expand = [a for a in target.actions if a.mnemonic == "TemplateExpand"][0]
    path_tools = expand.substitutions["@@PATH_TOOLS@@"]

    # The hub's directory, or on Windows the pinned git.exe's own (its
    # repository is the platform's).
    env.expect.that_bool("+tools+tbhb_rules_git" in path_tools).equals(True)
    env.expect.that_target(target).provider(RunEnvironmentInfo).environment().contains_exactly({
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TEMPLATE_DIR": "",
    })

def _test_rumdl_owns_its_root(name):
    util.helper_target(
        rumdl_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_rumdl_owns_its_root_impl, target = name + "_subject")

def _test_rumdl_owns_its_root_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@GIT_ROOT@@": "1",
    })

def _gitleaks_private_subject(name):
    util.helper_target(
        gitleaks_test,
        name = name,
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )

def _test_gitleaks_private_config(name):
    _gitleaks_private_subject(name + "_subject")
    analysis_test(
        name = name,
        impl = _test_gitleaks_private_config_impl,
        target = name + "_subject",
        config_settings = {str(Label("//lint:gitleaks_private_config")): True},
    )

def _test_gitleaks_private_config_impl(env, target):
    env.expect.that_collection(target[RunEnvironmentInfo].inherited_environment).contains_exactly(["GITLEAKS_CONFIG_TOML"])
    env.expect.that_dict(target[testing.ExecutionInfo].requirements).contains_exactly({"no-remote-cache": "1"})

def _test_gitleaks_without_private_config(name):
    _gitleaks_private_subject(name + "_subject")
    analysis_test(name = name, impl = _test_gitleaks_without_private_config_impl, target = name + "_subject")

def _test_gitleaks_without_private_config_impl(env, target):
    env.expect.that_collection(target[RunEnvironmentInfo].inherited_environment).contains_exactly([])
    env.expect.that_dict(target[testing.ExecutionInfo].requirements).contains_exactly({})

def tree_check_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_layout,
            _test_unstripped_paths_are_repository_relative,
            _test_file_outside_prefix_fails,
            _test_prefix_must_match_whole_directory,
            _test_config_placeholder_needs_config,
            _test_cache_path_cannot_escape,
            _test_cache_path_cannot_be_absolute,
            _test_cache_files_and_env,
            _test_gitleaks_guard,
            _test_gitleaks_private_config,
            _test_gitleaks_without_private_config,
            _test_tombi_schemas,
            _test_bats_uses_pinned_git,
            _test_rumdl_owns_its_root,
        ],
    )
