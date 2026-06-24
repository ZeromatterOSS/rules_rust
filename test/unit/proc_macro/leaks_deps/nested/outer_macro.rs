extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn outer(input: TokenStream) -> TokenStream {
    input
}
