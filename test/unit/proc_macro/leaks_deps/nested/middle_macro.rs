extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn middle(input: TokenStream) -> TokenStream {
    input
}
