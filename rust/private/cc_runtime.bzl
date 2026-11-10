# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Attributes for selecting the C++ toolchain runtime on Rust links."""

CC_RUNTIME_LINKAGE_ATTRS = {
    "cc_runtime_linkage": attr.string(
        doc = """Selects the C++ toolchain runtime libraries supplied to this link.

- `auto` (default): follow Rust std linkage (`link_std_dylib` or the toolchain's
  `experimental_link_std_dylib` setting), falling back to static if that is all
  the toolchain supplies.
- `static`: select the toolchain's static runtime libraries.
- `dynamic`: select the toolchain's dynamic runtime libraries; fail if only
  a static runtime is supplied.

Toolchains with no runtime libraries rely on their linker configuration.
Use `select()` for platform-specific policies. See [C++ runtime linkage](rust.md#c-runtime-linkage)
for defaults and scope.
""",
        values = ["auto", "dynamic", "static"],
        default = "auto",
    ),
}
