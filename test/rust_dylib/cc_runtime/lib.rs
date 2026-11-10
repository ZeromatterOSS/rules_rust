extern "C" {
    fn dylib_unwinder() -> *const ();
    fn dylib_cout() -> *const ();
}

pub fn runtime_addresses() -> (*const (), *const ()) {
    unsafe { (dylib_unwinder(), dylib_cout()) }
}
