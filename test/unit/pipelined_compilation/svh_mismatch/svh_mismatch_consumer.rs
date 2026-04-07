/// A library that depends on svh_lib. In worker-pipelining standalone mode,
/// this crate's metadata and full actions both depend on svh_lib's `.rmeta`
/// (a cross-tier dependency). If the separate rustc invocations for metadata
/// and full produce different SVHs (due to non-deterministic proc macros in
/// svh_lib), a downstream binary that loads this crate's `.rlib` will find
/// svh_lib's `.rlib` SVH doesn't match, causing E0463 or E0460.
///
/// In hollow-rlib mode, the graph is tier-consistent (hollow→hollow, full→full),
/// so this scenario does not arise.
pub use svh_lib::Widget;
