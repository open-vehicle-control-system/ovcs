//! What every segmentation Port shares: the request and the labels record
//! `VisionCore.Segmentation` exchanges with it, and the resize of a request's band to a
//! model's input.

pub mod band;
pub mod protocol;
