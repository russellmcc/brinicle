#![warn(nonstandard_style, rust_2018_idioms, future_incompatible)]

use brinicle_glue::generate_glue;
generate_glue!($PROJ_NAME$_kernel::Kernel);
