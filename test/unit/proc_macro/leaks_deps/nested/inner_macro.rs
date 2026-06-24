extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn inner(input: TokenStream) -> TokenStream {
    let _ = nested_helper::value();
    input
}
