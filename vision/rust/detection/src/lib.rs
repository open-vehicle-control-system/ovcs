//! What the vision Ports share: the detection Ports' record protocol, the letterbox between
//! the caller's image and the model's input, the bilinear resize under it, the
//! split of row-by-row work across threads, and box decoding.

pub mod bands;
pub mod bilinear;
pub mod letterbox;
pub mod nms;
pub mod protocol;
