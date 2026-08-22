//! Wire protocol for the DJI wireless microphone family.
//!
//! This crate is pure logic with no I/O: it frames and checksums packets,
//! builds commands, decodes heartbeats into a [`state::DeviceStatus`], and
//! describes each product's [`settings`]. The [`models`] registry lets a single
//! transport and UI drive any supported device, present or future.

pub mod crc;
pub mod models;
pub mod packet;
pub mod settings;
pub mod state;

pub use models::{model_by_id, model_for_usb, DeviceModel, MODELS};
pub use settings::{Setting, SettingKind, SettingOption, V2Target};
pub use state::{DeviceStatus, Firmware, RxInfo, TxInfo};
