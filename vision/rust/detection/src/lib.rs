//! What the object detection Ports share: their record protocol, the
//! letterbox between the caller's image and the model's input, and box
//! decoding.

pub mod letterbox;
pub mod nms;
pub mod protocol;
