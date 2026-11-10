extern "C" {
    fn binary_unwinder() -> *const ();
    fn binary_cout() -> *const ();
}

fn main() {
    let (dylib_unwinder, dylib_cout) = runtime_probe::runtime_addresses();
    unsafe {
        assert_eq!(binary_unwinder(), dylib_unwinder, "duplicate unwinders");
        assert_eq!(binary_cout(), dylib_cout, "duplicate C++ globals");
    }
}
