//! Platform detection and the Linux udev-rules helper.

use serde::Serialize;

/// The host operating system, as the UI needs to distinguish it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Os {
    Linux,
    MacOs,
    Windows,
    Other,
}

/// The OS this binary is running on.
pub fn current_os() -> Os {
    if cfg!(target_os = "linux") {
        Os::Linux
    } else if cfg!(target_os = "macos") {
        Os::MacOs
    } else if cfg!(target_os = "windows") {
        Os::Windows
    } else {
        Os::Other
    }
}

/// The filename the udev rule should be installed as.
pub const UDEV_RULE_FILE: &str = "/etc/udev/rules.d/60-dji-mic.rules";

/// The canonical udev rule granting non-root access to supported microphones.
///
/// `TAG+="uaccess"` hands the device to the locally logged-in user; the `MODE`
/// fallback covers systems without systemd-logind.
pub fn udev_rule() -> String {
    let mut out = String::from(
        "# DJI wireless microphones — non-root USB access\n\
         # Install to /etc/udev/rules.d/60-dji-mic.rules\n",
    );
    for &(vid, pid) in usb_ids().iter() {
        out.push_str(&format!(
            "SUBSYSTEM==\"usb\", ATTRS{{idVendor}}==\"{vid:04x}\", \
             ATTRS{{idProduct}}==\"{pid:04x}\", MODE=\"0660\", TAG+=\"uaccess\"\n"
        ));
    }
    out
}

/// Step-by-step instructions for applying the rule.
pub fn udev_instructions() -> Vec<String> {
    vec![
        format!("Save the rule below to {UDEV_RULE_FILE} (needs sudo)."),
        "Reload the rules: sudo udevadm control --reload-rules".to_string(),
        "Re-trigger: sudo udevadm trigger".to_string(),
        "Unplug and replug the receiver.".to_string(),
    ]
}

/// Every `(vendor, product)` id across all supported models.
fn usb_ids() -> Vec<(u16, u16)> {
    let mut ids: Vec<(u16, u16)> = protocol::MODELS
        .iter()
        .flat_map(|m| m.usb_ids().iter().copied())
        .collect();
    ids.sort_unstable();
    ids.dedup();
    ids
}
