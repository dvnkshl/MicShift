//! USB transport and multi-device orchestration for the DJI microphone family.
//!
//! [`DeviceManager`] discovers every supported microphone on the bus, runs a
//! background task per device (see [`actor`]), and exposes a small blocking API
//! the CLI and GUI share: [`DeviceManager::list`], [`DeviceManager::status`],
//! and [`DeviceManager::set`]. [`platform`] provides OS detection and the Linux
//! udev-rules helper.

mod actor;
pub mod error;
mod manager;
pub mod platform;

pub use error::{DeviceError, Result};
pub use manager::{DeviceManager, DeviceSummary, Probe};
pub use platform::{current_os, udev_instructions, udev_rule, Os, UDEV_RULE_FILE};

// Re-export the protocol surface front-ends need so they can depend on `device` alone.
pub use protocol::{self, DeviceStatus, Setting};
