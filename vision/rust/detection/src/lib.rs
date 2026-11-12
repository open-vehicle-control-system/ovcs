//! What the vision Ports share: the detection Ports' record protocol, the letterbox between
//! the caller's image and the model's input, the bilinear resize under it, and box decoding.

pub mod bilinear;
pub mod letterbox;
pub mod nms;
pub mod protocol;
