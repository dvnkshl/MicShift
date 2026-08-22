//! Per-product model definitions.
//!
//! A [`DeviceModel`] describes everything front-ends and the transport need to
//! know about one product: how to recognise it on USB, which settings it has,
//! how to build a command, and how to decode its status. Supporting a new
//! microphone — even one speaking a different protocol — means implementing this
//! trait and adding it to [`MODELS`]; nothing else changes.

mod mic_mini;

pub use mic_mini::MicMini;

use crate::packet::{self, Dialect};
use crate::settings::Setting;
use crate::state::DeviceStatus;

/// A supported microphone product.
pub trait DeviceModel: Send + Sync {
    /// Stable identifier, e.g. `"dji-mic-mini"`.
    fn id(&self) -> &'static str;
    /// Human name, e.g. `"DJI Mic Mini"`.
    fn name(&self) -> &'static str;
    /// Asset key the GUI maps to a pictogram.
    fn pictogram_key(&self) -> &'static str;

    /// `(vendor, product)` id pairs this model matches.
    fn usb_ids(&self) -> &'static [(u16, u16)];
    /// Vendor interface number to claim.
    fn interface(&self) -> u8;
    /// Interfaces (besides the claimed vendor one) whose kernel driver must be
    /// detached for bulk I/O to work. Keep this minimal so unrelated interfaces
    /// — notably USB Audio — stay bound to their drivers and the device remains
    /// usable as a normal sound device.
    fn detach_interfaces(&self) -> &'static [u8] {
        &[]
    }
    /// Bulk IN endpoint (device → host).
    fn bulk_in(&self) -> u8;
    /// Bulk OUT endpoint (host → device).
    fn bulk_out(&self) -> u8;

    /// The settings this model exposes.
    fn settings(&self) -> &'static [Setting];

    /// Build a command packet setting `setting_id` to the option `value`, in
    /// the wire shape `dialect` calls for.
    ///
    /// `tx` is the 0-based transmitter slot to address, required (and only
    /// consulted) when the setting's [`V2Target`](crate::settings::V2Target)
    /// is `Tx` — e.g. Voice Tone, which doesn't mirror across TX the way
    /// every other transmitter setting does.
    ///
    /// The default implementation frames a standard DUML command from the
    /// setting's command id(s) and the option's wire byte. Returns `None` if
    /// the setting or value is unknown, `setting_id` doesn't exist under
    /// `dialect` (e.g. a v2-only setting requested in [`Dialect::V1`]), or a
    /// `Tx`-targeted setting was built without a `tx`.
    fn build_command(
        &self,
        seq: u16,
        dialect: Dialect,
        setting_id: &str,
        value: &str,
        tx: Option<usize>,
    ) -> Option<Vec<u8>> {
        let setting = self.settings().iter().find(|s| s.id == setting_id)?;
        let option = setting.option(value)?;
        match dialect {
            Dialect::V1 => {
                let command = setting.v1_command?;
                Some(packet::build_v1_command(seq, command, option.wire))
            }
            Dialect::V2 => {
                let target = match setting.v2_target {
                    crate::settings::V2Target::Fixed(t) => t,
                    crate::settings::V2Target::Tx => u16::try_from(tx?).ok()?.checked_add(1)?,
                };
                Some(packet::build_v2_command(seq, target, setting.v2_command, option.wire))
            }
        }
    }

    /// Decode a device→host frame, or `None` if it's not one this model
    /// understands.
    ///
    /// `previous` is the status as of the last decoded frame. Most dialects
    /// push one self-sufficient snapshot per heartbeat and can ignore it, but
    /// some (see `PROTOCOL.md`'s v2 identity/level pushes) split a single
    /// logical status across several periodic frame types; those need
    /// `previous` to carry forward what this particular frame doesn't carry,
    /// rather than reverting it to unknown on every tick.
    fn decode(&self, previous: &DeviceStatus, frame: &[u8]) -> Option<DeviceStatus>;
}

/// Every supported model.
pub const MODELS: &[&dyn DeviceModel] = &[&MicMini];

/// Find the model matching a USB `(vendor, product)` pair.
pub fn model_for_usb(vendor: u16, product: u16) -> Option<&'static dyn DeviceModel> {
    MODELS
        .iter()
        .copied()
        .find(|m| m.usb_ids().contains(&(vendor, product)))
}

/// Find a model by its identifier.
pub fn model_by_id(id: &str) -> Option<&'static dyn DeviceModel> {
    MODELS.iter().copied().find(|m| m.id() == id)
}
