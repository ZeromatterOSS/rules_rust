"""
Tests for handling of cc_toolchain's static_runtime_lib/dynamic_runtime_lib.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "feature")
load("@rules_cc//cc:defs.bzl", "cc_import", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("//rust:defs.bzl", "rust_binary", "rust_doc_test", "rust_dylib_library", "rust_library", "rust_shared_library", "rust_static_library")

def _test_cc_config_impl(ctx):
    config_info = cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "test-cc-toolchain",
        host_system_name = "unknown",
        target_system_name = "unknown",
        target_cpu = "unknown",
        target_libc = "unknown",
        compiler = "unknown",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        features = [
            feature(name = "static_link_cpp_runtimes", enabled = True),
        ],
    )
    return config_info

test_cc_config = rule(
    implementation = _test_cc_config_impl,
    provides = [CcToolchainConfigInfo],
)

def _with_extra_toolchain_transition_impl(_settings, attr):
    return {"//command_line_option:extra_toolchains": [attr.extra_toolchain]}

with_extra_toolchain_transition = transition(
    implementation = _with_extra_toolchain_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:extra_toolchains"],
)

DepActionsInfo = provider(
    "Contains information about dependencies actions.",
    fields = {
        "actions": "List[Action]",
        "runfiles": "List[File]",
    },
)

def _with_extra_toolchain_impl(ctx):
    return [
        DepActionsInfo(
            actions = ctx.attr.target[0].actions,
            runfiles = ctx.attr.target[0][DefaultInfo].default_runfiles.files.to_list(),
        ),
    ]

with_extra_toolchain = rule(
    implementation = _with_extra_toolchain_impl,
    attrs = {
        "extra_toolchain": attr.label(),
        "target": attr.label(cfg = with_extra_toolchain_transition),
    },
)

def _inputs_analysis_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    matching_actions = [action for action in tut[DepActionsInfo].actions if action.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, 1, len(matching_actions))
    if not matching_actions:
        return analysistest.end(env)
    action = matching_actions[0]
    inputs = action.inputs.to_list()
    for expected in ctx.attr.expected_inputs:
        asserts.true(
            env,
            any([input.path.endswith("/" + expected) for input in inputs]),
            "error: expected '{}' to be in inputs: '{}'".format(expected, inputs),
        )

    for unexpected in ctx.attr.unexpected_inputs:
        asserts.false(
            env,
            any([input.path.endswith("/" + unexpected) for input in inputs]),
            "error: did not expect '{}' in inputs: '{}'".format(unexpected, inputs),
        )

    for expected in ctx.attr.expected_link_arg_inputs:
        asserts.true(
            env,
            any([arg.startswith("-Clink-arg=") and arg.endswith("/" + expected) for arg in action.argv]),
            "error: expected '{}' to be linked via -Clink-arg: '{}'".format(expected, action.argv),
        )

    for expected in ctx.attr.expected_link_inputs:
        asserts.true(
            env,
            any([arg.endswith("/" + expected) for arg in action.argv]),
            "error: expected '{}' in link args: '{}'".format(expected, action.argv),
        )

    for expected in ctx.attr.expected_args:
        asserts.true(
            env,
            expected in action.argv,
            "error: expected '{}' in args: '{}'".format(expected, action.argv),
        )

    for unexpected in ctx.attr.unexpected_args:
        asserts.false(
            env,
            unexpected in action.argv,
            "error: did not expect '{}' in args: '{}'".format(unexpected, action.argv),
        )

    if ctx.attr.expected_any_of:
        # MSVC accepts bare library names; other linkers use the -l prefix.
        asserts.true(
            env,
            any([expected in action.argv for expected in ctx.attr.expected_any_of]),
            "error: expected one of {} in args: '{}'".format(ctx.attr.expected_any_of, action.argv),
        )

    runfiles = tut[DepActionsInfo].runfiles
    for expected in ctx.attr.expected_runfiles:
        asserts.true(
            env,
            any([runfile.path.endswith("/" + expected) for runfile in runfiles]),
            "error: expected '{}' to be in runfiles: '{}'".format(expected, runfiles),
        )

    for unexpected in ctx.attr.unexpected_runfiles:
        asserts.false(
            env,
            any([runfile.path.endswith("/" + unexpected) for runfile in runfiles]),
            "error: did not expect '{}' in runfiles: '{}'".format(unexpected, runfiles),
        )

    for prefix in ctx.attr.expected_solib_runfile_prefixes:
        asserts.true(
            env,
            any([runfile.short_path.startswith("_solib_") and runfile.basename.startswith(prefix) for runfile in runfiles]),
            "error: expected solib runfile starting with '{}': '{}'".format(prefix, runfiles),
        )

    return analysistest.end(env)

_INPUTS_ANALYSIS_TEST_ATTRS = {
    "mnemonic": attr.string(default = "Rustc"),
    "expected_inputs": attr.string_list(),
    "expected_args": attr.string_list(),
    "expected_any_of": attr.string_list(),
    "expected_link_arg_inputs": attr.string_list(),
    "expected_link_inputs": attr.string_list(),
    "expected_runfiles": attr.string_list(),
    "expected_solib_runfile_prefixes": attr.string_list(),
    "unexpected_args": attr.string_list(),
    "unexpected_inputs": attr.string_list(),
    "unexpected_runfiles": attr.string_list(),
}

inputs_analysis_test = analysistest.make(
    impl = _inputs_analysis_test_impl,
    doc = "An analysistest to examine the inputs of a library target.",
    attrs = _INPUTS_ANALYSIS_TEST_ATTRS,
)

global_std_inputs_analysis_test = analysistest.make(
    impl = _inputs_analysis_test_impl,
    attrs = _INPUTS_ANALYSIS_TEST_ATTRS,
    config_settings = {str(Label("//rust/settings:experimental_link_std_dylib")): True},
)

rustdoc_link_args_analysis_test = analysistest.make(
    impl = _inputs_analysis_test_impl,
    attrs = _INPUTS_ANALYSIS_TEST_ATTRS | {"mnemonic": attr.string(default = "RustdocTest")},
)

def _dynamic_runtime_unavailable_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "C++ toolchain supplies only a static runtime")
    return analysistest.end(env)

dynamic_runtime_unavailable_test = analysistest.make(
    _dynamic_runtime_unavailable_test_impl,
    expect_failure = True,
)

def runtime_libs_test(name):
    """Produces test shared and static library targets that are set up to use a custom cc_toolchain with custom runtime libs.

    Args:
      name: The name of the test target.
    """

    dylib_platforms = select({
        "@platforms//os:linux": [],
        "@platforms//os:macos": [],
        "//conditions:default": ["@platforms//:incompatible"],
    })

    test_cc_config(
        name = "%s/cc_toolchain_config" % name,
    )
    native.filegroup(name = "empty_runtime", srcs = [])
    for suffix, identifier, static_runtime, dynamic_runtime in [
        ("test", "dummy_wasm32_cc", ":dummy.a", ":dummy.so"),
        ("static_only", "static_only_cc", ":dummy.a", ":empty_runtime"),
        ("no_runtime", "no_runtime_cc", ":empty_runtime", ":empty_runtime"),
    ]:
        cc_toolchain(
            name = "%s/%s_cc_toolchain_impl" % (name, suffix),
            all_files = ":empty",
            compiler_files = ":empty",
            dwp_files = ":empty",
            linker_files = ":empty",
            objcopy_files = ":empty",
            strip_files = ":empty",
            supports_param_files = 0,
            toolchain_config = ":%s/cc_toolchain_config" % name,
            toolchain_identifier = identifier,
            static_runtime_lib = static_runtime,
            dynamic_runtime_lib = dynamic_runtime,
        )
        native.toolchain(
            name = "%s/%s_cc_toolchain" % (name, suffix),
            toolchain = ":%s/%s_cc_toolchain_impl" % (name, suffix),
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )

    rust_shared_library(
        name = "%s/__shared_library" % name,
        cc_runtime_linkage = "dynamic",
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_shared_library" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__shared_library" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/shared_library" % name,
        target_under_test = "%s/_shared_library" % name,
        expected_inputs = ["dummy.so"],
        expected_args = select({
            "@platforms//os:windows": ["-ldylib=dummy"],
            "//conditions:default": [],
        }),
        expected_link_arg_inputs = select({
            "@platforms//os:windows": [],
            "//conditions:default": ["dummy.so"],
        }),
        expected_runfiles = ["dummy.so"],
        unexpected_args = select({
            "@platforms//os:windows": [],
            "//conditions:default": ["-ldylib=dummy"],
        }),
    )

    # Dynamic Rust std selects the dynamic C++ toolchain runtime by default.
    rust_dylib_library(
        name = "%s/__dylib_dep" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    rust_binary(
        name = "%s/__binary_with_dylib_dep" % name,
        edition = "2018",
        srcs = ["main.rs"],
        link_std_dylib = True,
        deps = [":%s/__dylib_dep" % name],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_dylib_dep" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_dylib_dep" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_dylib_dep" % name,
        target_under_test = "%s/_binary_with_dylib_dep" % name,
        expected_inputs = ["dummy.so"],
        expected_link_arg_inputs = select({
            "@platforms//os:windows": [],
            "//conditions:default": ["dummy.so"],
        }),
        expected_runfiles = ["dummy.so"],
        unexpected_inputs = ["dummy.a"],
        target_compatible_with = dylib_platforms,
    )

    # The default follows Rust std even without dylib crate dependencies.
    rust_binary(
        name = "%s/__binary_with_std_dylib" % name,
        edition = "2018",
        srcs = ["main.rs"],
        link_std_dylib = True,
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_binary_with_std_dylib" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__binary_with_std_dylib" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/binary_with_std_dylib" % name,
        target_under_test = "%s/_binary_with_std_dylib" % name,
        expected_inputs = ["dummy.so"],
        expected_link_arg_inputs = ["dummy.so"],
        expected_runfiles = ["dummy.so"],
        unexpected_inputs = ["dummy.a"],
        target_compatible_with = dylib_platforms,
    )

    # Dependency crate types do not override the configured Rust std policy.
    rust_library(
        name = "%s/__intermediate" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        deps = [":%s/__dylib_dep" % name],
        tags = ["manual", "nobuild"],
    )
    rust_binary(
        name = "%s/__transitive_dylib" % name,
        edition = "2018",
        srcs = ["main.rs"],
        deps = [":%s/__intermediate" % name],
        tags = ["manual", "nobuild"],
    )
    with_extra_toolchain(
        name = "%s/_transitive_dylib" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__transitive_dylib" % name,
        tags = ["manual"],
    )
    inputs_analysis_test(
        name = "%s/transitive_dylib" % name,
        target_under_test = "%s/_transitive_dylib" % name,
        expected_inputs = ["dummy.a"],
        expected_args = ["-lstatic=dummy"],
        # The dylib still needs its own dynamic runtime deployed.
        expected_runfiles = ["dummy.so"],
        unexpected_inputs = ["dummy.so"],
        target_compatible_with = dylib_platforms,
    )

    # Supply both forms of an ordinary native dependency. Selecting a dynamic
    # runtime must not also change this dependency to dynamic linkage.
    native.genrule(
        name = "%s/native_libraries" % name,
        outs = ["libnative.a", "libnative.so"],
        cmd = "touch $(OUTS)",
        tags = ["manual"],
    )
    cc_import(
        name = "%s/native_dep" % name,
        static_library = ":libnative.a",
        shared_library = ":libnative.so",
        tags = ["manual"],
    )
    rust_binary(
        name = "%s/__cc_common_binary" % name,
        edition = "2018",
        srcs = ["main.rs"],
        link_std_dylib = True,
        experimental_use_cc_common_link = 1,
        deps = [":%s/native_dep" % name],
        tags = ["manual", "nobuild"],
    )
    for suffix, toolchain, dynamic in [
        ("cc_common_dynamic", "test_cc_toolchain", True),
        ("cc_common_static_only", "static_only_cc_toolchain", False),
    ]:
        with_extra_toolchain(
            name = "%s/_%s" % (name, suffix),
            extra_toolchain = ":%s/%s" % (name, toolchain),
            target = "%s/__cc_common_binary" % name,
            tags = ["manual"],
        )
        inputs_analysis_test(
            name = "%s/%s" % (name, suffix),
            target_under_test = "%s/_%s" % (name, suffix),
            mnemonic = "CppLink",
            expected_inputs = ["libnative.a"] + (["dummy.so"] if dynamic else ["dummy.a"]),
            expected_link_inputs = ["libnative.a"] + ([] if dynamic else ["dummy.a"]),
            expected_runfiles = ["dummy.so"] if dynamic else [],
            expected_solib_runfile_prefixes = ["libstd-"],
            unexpected_inputs = ["libnative.so"] + (["dummy.a"] if dynamic else ["dummy.so"]),
            unexpected_runfiles = [] if dynamic else ["dummy.a", "dummy.so"],
            target_compatible_with = dylib_platforms,
        )

    with_extra_toolchain(
        name = "%s/_static_only_binary" % name,
        extra_toolchain = ":%s/static_only_cc_toolchain" % name,
        target = "%s/__binary_with_std_dylib" % name,
        tags = ["manual"],
    )
    inputs_analysis_test(
        name = "%s/static_only_binary" % name,
        target_under_test = "%s/_static_only_binary" % name,
        expected_inputs = ["dummy.a"],
        expected_args = ["-lstatic=dummy"],
        unexpected_inputs = ["dummy.so"],
        unexpected_runfiles = ["dummy.a", "dummy.so"],
    )

    with_extra_toolchain(
        name = "%s/_static_only_shared_library" % name,
        extra_toolchain = ":%s/static_only_cc_toolchain" % name,
        target = "%s/__dylib_dep" % name,
        tags = ["manual"],
    )
    inputs_analysis_test(
        name = "%s/static_only_shared_library" % name,
        target_under_test = "%s/_static_only_shared_library" % name,
        expected_inputs = ["dummy.a"],
        expected_args = ["-lstatic=dummy"],
        unexpected_inputs = ["dummy.so"],
        unexpected_runfiles = ["dummy.a", "dummy.so"],
    )

    rust_shared_library(
        name = "%s/__static_override" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        cc_runtime_linkage = "static",
        tags = ["manual", "nobuild"],
    )
    with_extra_toolchain(
        name = "%s/_static_override" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__static_override" % name,
        tags = ["manual"],
    )
    inputs_analysis_test(
        name = "%s/static_override" % name,
        target_under_test = "%s/_static_override" % name,
        expected_inputs = ["dummy.a"],
        expected_args = ["-lstatic=dummy"],
        unexpected_inputs = ["dummy.so"],
        unexpected_runfiles = ["dummy.a", "dummy.so"],
    )

    # Doctests use their own Rust std and C++ runtime policy for the test link.
    rust_library(
        name = "%s/__doctest_library_with_dylib_dep" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        deps = [":%s/__dylib_dep" % name],
        tags = ["manual", "nobuild"],
    )

    rust_doc_test(
        name = "%s/__doc_test_with_dylib_dep" % name,
        link_std_dylib = True,
        crate = ":%s/__doctest_library_with_dylib_dep" % name,
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_doc_test_with_dylib_dep" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__doc_test_with_dylib_dep" % name,
        tags = ["manual"],
        testonly = True,
    )

    rustdoc_link_args_analysis_test(
        name = "%s/doc_test_with_dylib_dep" % name,
        target_under_test = "%s/_doc_test_with_dylib_dep" % name,
        expected_link_arg_inputs = ["dummy.so"],
        target_compatible_with = dylib_platforms,
    )

    with_extra_toolchain(
        name = "%s/_doc_test_static_only" % name,
        extra_toolchain = ":%s/static_only_cc_toolchain" % name,
        target = "%s/__doc_test_with_dylib_dep" % name,
        tags = ["manual"],
        testonly = True,
    )
    rustdoc_link_args_analysis_test(
        name = "%s/doc_test_static_only" % name,
        target_under_test = "%s/_doc_test_static_only" % name,
        expected_any_of = ["-Clink-arg=-ldummy", "-Clink-arg=dummy"],
    )

    rust_static_library(
        name = "%s/__static_library" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_static_library" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__static_library" % name,
        tags = ["manual"],
    )

    inputs_analysis_test(
        name = "%s/static_library" % name,
        target_under_test = "%s/_static_library" % name,
        expected_inputs = ["dummy.a"],
    )

    # A doc test links like a binary, so it needs the static runtime lib named
    # on the command line. `dummy.a` yields `dummy` via `get_lib_name`, spelled
    # `-ldummy` everywhere except msvc.
    rust_library(
        name = "%s/__doctest_library" % name,
        edition = "2018",
        srcs = ["lib.rs"],
        tags = ["manual", "nobuild"],
    )

    rust_doc_test(
        name = "%s/__doc_test" % name,
        crate = ":%s/__doctest_library" % name,
        tags = ["manual", "nobuild"],
    )

    with_extra_toolchain(
        name = "%s/_doc_test" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__doc_test" % name,
        tags = ["manual"],
        # rust_doc_test is a test rule, so it is testonly.
        testonly = True,
    )

    rustdoc_link_args_analysis_test(
        name = "%s/doc_test" % name,
        target_under_test = "%s/_doc_test" % name,
        expected_any_of = [
            "-Clink-arg=-ldummy",
            # msvc: link.exe takes bare library names, no `-l`.
            "-Clink-arg=dummy",
        ],
    )

    # Explicit selections override either Rust std setting on both link paths.
    for cc_common_link in [0, 1]:
        for std_dynamic in [False, True]:
            for policy in ["auto", "static", "dynamic"]:
                suffix = "policy_%s_%s_%s" % (cc_common_link, std_dynamic, policy)
                dynamic = policy == "dynamic" or (policy == "auto" and std_dynamic)
                rust_binary(
                    name = "%s/__%s" % (name, suffix),
                    srcs = ["main.rs"],
                    link_std_dylib = std_dynamic,
                    cc_runtime_linkage = policy,
                    experimental_use_cc_common_link = cc_common_link,
                    deps = [":%s/native_dep" % name],
                    tags = ["manual", "nobuild"],
                )
                with_extra_toolchain(
                    name = "%s/_%s" % (name, suffix),
                    extra_toolchain = ":%s/test_cc_toolchain" % name,
                    target = "%s/__%s" % (name, suffix),
                    tags = ["manual"],
                )
                inputs_analysis_test(
                    name = "%s/%s" % (name, suffix),
                    target_under_test = "%s/_%s" % (name, suffix),
                    mnemonic = "CppLink" if cc_common_link else "Rustc",
                    expected_inputs = ["libnative.a", "dummy.so" if dynamic else "dummy.a"],
                    expected_args = ["-lstatic=dummy"] if not dynamic and not cc_common_link else [],
                    expected_link_arg_inputs = ["dummy.so"] if dynamic and not cc_common_link else [],
                    expected_runfiles = ["dummy.so"] if dynamic else [],
                    unexpected_inputs = ["libnative.so", "dummy.a" if dynamic else "dummy.so"],
                    unexpected_runfiles = [] if dynamic else ["dummy.so"],
                    target_compatible_with = dylib_platforms,
                )

    # A shared output alone does not imply a dynamic Rust standard library.
    for kind, rule in [("cdylib", rust_shared_library), ("dylib", rust_dylib_library)]:
        rule(
            name = "%s/__auto_static_%s" % (name, kind),
            srcs = ["lib.rs"],
            tags = ["manual", "nobuild"],
            **({"link_std_dylib": False} if kind == "dylib" else {})
        )
        with_extra_toolchain(
            name = "%s/_auto_static_%s" % (name, kind),
            extra_toolchain = ":%s/test_cc_toolchain" % name,
            target = "%s/__auto_static_%s" % (name, kind),
            tags = ["manual"],
        )
        inputs_analysis_test(
            name = "%s/auto_static_%s" % (name, kind),
            target_under_test = "%s/_auto_static_%s" % (name, kind),
            expected_inputs = ["dummy.a"],
            expected_args = ["-lstatic=dummy"],
            unexpected_inputs = ["dummy.so"],
            unexpected_runfiles = ["dummy.so"],
        )

    with_extra_toolchain(
        name = "%s/_unavailable_dynamic" % name,
        extra_toolchain = ":%s/static_only_cc_toolchain" % name,
        target = "%s/__shared_library" % name,
        tags = ["manual"],
    )
    dynamic_runtime_unavailable_test(
        name = "%s/unavailable_dynamic" % name,
        target_under_test = "%s/_unavailable_dynamic" % name,
    )

    rust_doc_test(
        name = "%s/__doc_test_static_override" % name,
        crate = ":%s/__doctest_library" % name,
        link_std_dylib = True,
        cc_runtime_linkage = "static",
        tags = ["manual", "nobuild"],
    )
    with_extra_toolchain(
        name = "%s/_doc_test_static_override" % name,
        extra_toolchain = ":%s/test_cc_toolchain" % name,
        target = "%s/__doc_test_static_override" % name,
        tags = ["manual"],
        testonly = True,
    )
    rustdoc_link_args_analysis_test(
        name = "%s/doc_test_static_override" % name,
        target_under_test = "%s/_doc_test_static_override" % name,
        expected_any_of = ["-Clink-arg=-ldummy", "-Clink-arg=dummy"],
    )

    # The build-wide Rust std setting takes effect even when the target's flag
    # is false, and an explicit C++ override still wins on the cc_common path.
    for suffix, dynamic, mnemonic in [
        ("policy_0_False_auto", True, "Rustc"),
        ("auto_static_cdylib", True, "Rustc"),
        ("policy_1_False_static", False, "CppLink"),
    ]:
        global_std_inputs_analysis_test(
            name = "%s/global_std_%s" % (name, suffix),
            target_under_test = "%s/_%s" % (name, suffix),
            mnemonic = mnemonic,
            expected_inputs = ["dummy.so" if dynamic else "dummy.a"],
            expected_runfiles = ["dummy.so"] if dynamic else [],
            unexpected_inputs = ["dummy.a" if dynamic else "dummy.so"],
            target_compatible_with = dylib_platforms,
        )

    # An empty explicit runtime set can mean the toolchain configures the
    # runtime through linker flags. Even an explicit dynamic policy permits it.
    with_extra_toolchain(
        name = "%s/_no_runtime" % name,
        extra_toolchain = ":%s/no_runtime_cc_toolchain" % name,
        target = "%s/__shared_library" % name,
        tags = ["manual"],
    )
    inputs_analysis_test(
        name = "%s/no_runtime" % name,
        target_under_test = "%s/_no_runtime" % name,
        unexpected_inputs = ["dummy.a", "dummy.so"],
        unexpected_runfiles = ["dummy.a", "dummy.so"],
    )
