use proc_macro::TokenStream;

const _FORTY_TWO: i32 = proc_macro_definition::make_forty_two!();

#[proc_macro]
pub fn identity(item: TokenStream) -> TokenStream {
    item
}
