/// Demonstrates SVH (Strict Version Hash) sensitivity with pipelined compilation.
///
/// The two pipelining modes use different metadata classes with different safety
/// properties (see DESIGN.md "Metadata Classes"):
///
/// - **Full metadata** (hollow_rlib mode, Buck2-style): tier-consistent graph,
///   safe with all execution strategies, non-deterministic proc macros OK.
/// - **Fast metadata** (worker mode, Cargo-style): requires same rustc process,
///   non-deterministic proc macros fail under separate-process execution.
///
/// Without pipelining this test always builds and passes: each library is
/// compiled exactly once, so the SVH embedded in every `.rmeta` and `.rlib`
/// is identical.
///
/// With `experimental_pipelined_compilation=hollow_rlib` (full metadata), each
/// library is compiled twice in separate rustc processes — once with
/// `-Zno-codegen` for the hollow rlib and once for the full rlib. The
/// dependency graph is **tier-consistent**: the hollow action depends on
/// upstream hollow rlibs, and the full action depends on upstream full rlibs.
/// Each tier has self-consistent SVH values, so there is no cross-tier mismatch
/// even with non-deterministic proc macros. The build always succeeds. This is
/// why hollow_rlib is the recommended portable mode.
///
/// With `experimental_pipelined_compilation=worker` (fast metadata) under
/// **worker execution**, each library is compiled by a single rustc process,
/// so the proc macro runs once and SVH is trivially consistent. The build
/// always succeeds.
///
/// With `experimental_pipelined_compilation=worker` (fast metadata) under
/// **non-worker execution** (sandboxed, local, remote), the metadata and full
/// actions run as separate rustc processes, but both depend on upstream
/// `.rmeta` (a cross-tier dependency). Non-deterministic proc macros produce
/// different SVHs in each process, and downstream consumers see an SVH
/// mismatch (E0463 or E0460). This is the scenario the test exercises.
///
/// The `flaky = True` attribute acknowledges that the mismatch is non-
/// deterministic: on rare occasions (~0.8%) both rustc invocations happen
/// to produce the same HashMap iteration order, the SVHs agree, and the
/// build succeeds.
use svh_consumer::Widget;

#[test]
fn svh_consistent() {
    // If we reach here the SVH was consistent (no pipelining, or a lucky run).
    let _: Widget = Widget;
}
