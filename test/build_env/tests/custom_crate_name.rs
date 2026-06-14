#[test]
fn cargo_env_vars() {
    assert_eq!(env!("CARGO_PKG_NAME"), "cargo_pkg_env_test");
    assert_eq!(env!("CARGO_PKG_VERSION"), "1.2.3");
    assert_eq!(env!("CARGO_CRATE_NAME"), "custom_crate_name");
}
