use std::env;
use std::io::{self, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use device::{DeviceManager, DeviceStatus};
use futures_lite::future;
use nusb::transfer::{Direction, EndpointType, RequestBuffer};
use protocol::model_for_usb;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
struct TransmitterSnapshot {
    slot: usize,
    charging: Option<bool>,
    battery: Option<u8>,
    level: Option<u8>,
    product_name: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct Snapshot {
    receiver_present: bool,
    receiver_accessible: bool,
    receiver_streaming: bool,
    device_id: Option<String>,
    protocol_version: Option<u8>,
    transmitters: Vec<TransmitterSnapshot>,
}

#[derive(Clone, Debug, Serialize)]
struct DiscoveryEndpoint {
    address: u8,
    direction: &'static str,
    transfer_type: &'static str,
    max_packet_size: usize,
    interval: u8,
}

#[derive(Clone, Debug, Serialize)]
struct DiscoveryInterface {
    number: u8,
    alternate_setting: u8,
    class: u8,
    subclass: u8,
    protocol: u8,
    endpoints: Vec<DiscoveryEndpoint>,
}

#[derive(Clone, Debug, Serialize)]
struct DiscoveryDevice {
    vendor_id: u16,
    product_id: u16,
    device_version: u16,
    manufacturer: Option<String>,
    product: Option<String>,
    serial_redacted: bool,
    known_model: Option<String>,
    capture_supported: bool,
    interfaces: Vec<DiscoveryInterface>,
}

#[derive(Debug, Serialize)]
struct CaptureStarted {
    kind: &'static str,
    schema_version: u8,
    timestamp_ms: u128,
    device: DiscoveryDevice,
    safety: &'static str,
}

#[derive(Debug, Serialize)]
struct CapturePacket {
    kind: &'static str,
    timestamp_ms: u128,
    interface: u8,
    endpoint: u8,
    transfer_type: &'static str,
    length: usize,
    data_hex: String,
    redacted_ascii_ranges: Vec<[usize; 2]>,
}

#[derive(Debug, Serialize)]
struct CaptureNotice {
    kind: &'static str,
    timestamp_ms: u128,
    message: String,
}

impl Snapshot {
    fn from_manager(manager: &DeviceManager) -> Self {
        let probe = manager.probe();
        let devices = manager.list();
        let selected = devices
            .iter()
            .find(|device| device.connected)
            .or_else(|| devices.first());

        let status = selected.and_then(|device| manager.status(&device.id).ok());
        let receiver_streaming = status.as_ref().is_some_and(|status| status.connected);

        Self {
            receiver_present: probe.present > 0,
            receiver_accessible: probe.accessible > 0,
            receiver_streaming,
            device_id: selected.map(|device| device.id.clone()),
            protocol_version: status.as_ref().and_then(|status| status.protocol_version),
            transmitters: status.as_ref().map(transmitters).unwrap_or_default(),
        }
    }
}

fn transmitters(status: &DeviceStatus) -> Vec<TransmitterSnapshot> {
    status
        .tx
        .iter()
        .enumerate()
        .filter_map(|(index, tx)| {
            tx.as_ref().map(|tx| TransmitterSnapshot {
                slot: index + 1,
                charging: tx.charging,
                battery: tx.battery,
                level: tx.level,
                product_name: tx.product_name.clone(),
            })
        })
        .collect()
}

fn monitor() -> Result<(), Box<dyn std::error::Error>> {
    let manager = DeviceManager::new();
    let mut last_line = String::new();
    let mut last_emit = Instant::now() - Duration::from_secs(10);
    // The helper normally exits when LinkMonitor closes it. This additional
    // parent check covers Force Quit and app crashes, where Swift cannot run
    // applicationWillTerminate and the stdout watchdog can take up to 2s.
    let parent_pid = unsafe { libc::getppid() };

    loop {
        if unsafe { libc::getppid() } != parent_pid {
            return Ok(());
        }
        manager.refresh();
        let line = serde_json::to_string(&Snapshot::from_manager(&manager))?;

        // Emit immediately when state changes and periodically as a watchdog.
        if line != last_line || last_emit.elapsed() >= Duration::from_secs(2) {
            println!("{line}");
            io::stdout().flush()?;
            last_line = line;
            last_emit = Instant::now();
        }

        thread::sleep(Duration::from_millis(250));
    }
}

fn discovery_devices() -> Result<Vec<DiscoveryDevice>, Box<dyn std::error::Error>> {
    let mut devices = Vec::new();
    for info in nusb::list_devices()? {
        let manufacturer = info.manufacturer_string().map(ToOwned::to_owned);
        let product = info.product_string().map(ToOwned::to_owned);
        let is_dji = info.vendor_id() == 0x2ca3
            || manufacturer
                .as_deref()
                .is_some_and(|value| value.to_ascii_lowercase().contains("dji"));
        let summary_has_audio = info.interfaces().any(|interface| interface.class() == 0x01);
        let summary_has_vendor = info.interfaces().any(|interface| interface.class() == 0xff);
        let name_suggests_microphone = product.as_deref().is_some_and(|value| {
            let value = value.to_ascii_lowercase();
            value.contains("mic") || value.contains("receiver") || value.contains("wireless")
        });

        // Keep the picker useful: DJI hardware plus composite audio devices
        // that expose a separate vendor-control interface are the candidates
        // from which clean link/battery state can realistically be learned.
        if !is_dji && !(summary_has_audio && summary_has_vendor) && !name_suggests_microphone {
            continue;
        }

        devices.push(discovery_device(&info));
    }
    devices.sort_by(|left, right| {
        left.manufacturer
            .cmp(&right.manufacturer)
            .then(left.product.cmp(&right.product))
            .then(left.vendor_id.cmp(&right.vendor_id))
            .then(left.product_id.cmp(&right.product_id))
    });
    Ok(devices)
}

fn discovery_device(info: &nusb::DeviceInfo) -> DiscoveryDevice {
    let mut interfaces = Vec::new();
    if let Ok(device) = info.open() {
        if let Ok(configuration) = device.active_configuration() {
            for group in configuration.interfaces() {
                for alternate in group.alt_settings() {
                    interfaces.push(DiscoveryInterface {
                        number: alternate.interface_number(),
                        alternate_setting: alternate.alternate_setting(),
                        class: alternate.class(),
                        subclass: alternate.subclass(),
                        protocol: alternate.protocol(),
                        endpoints: alternate
                            .endpoints()
                            .map(|endpoint| DiscoveryEndpoint {
                                address: endpoint.address(),
                                direction: direction_name(endpoint.direction()),
                                transfer_type: endpoint_type_name(endpoint.transfer_type()),
                                max_packet_size: endpoint.max_packet_size(),
                                interval: endpoint.interval(),
                            })
                            .collect(),
                    });
                }
            }
        }
    }

    // Opening can fail while another app owns the device. Interface summaries
    // still identify the candidate without claiming or detaching anything.
    if interfaces.is_empty() {
        interfaces = info
            .interfaces()
            .map(|interface| DiscoveryInterface {
                number: interface.interface_number(),
                alternate_setting: 0,
                class: interface.class(),
                subclass: interface.subclass(),
                protocol: interface.protocol(),
                endpoints: Vec::new(),
            })
            .collect();
    }

    let capture_supported = interfaces.iter().any(|interface| {
        interface.class == 0xff
            && interface.endpoints.iter().any(|endpoint| {
                endpoint.direction == "in"
                    && (endpoint.transfer_type == "bulk" || endpoint.transfer_type == "interrupt")
            })
    });

    DiscoveryDevice {
        vendor_id: info.vendor_id(),
        product_id: info.product_id(),
        device_version: info.device_version(),
        manufacturer: info.manufacturer_string().map(ToOwned::to_owned),
        product: info.product_string().map(ToOwned::to_owned),
        serial_redacted: info
            .serial_number()
            .is_some_and(|serial| !serial.is_empty()),
        known_model: model_for_usb(info.vendor_id(), info.product_id())
            .map(|model| model.name().to_string()),
        capture_supported,
        interfaces,
    }
}

fn list_discovery_devices() -> Result<(), Box<dyn std::error::Error>> {
    println!("{}", serde_json::to_string(&discovery_devices()?)?);
    Ok(())
}

fn capture_discovery(vendor_id: u16, product_id: u16) -> Result<(), Box<dyn std::error::Error>> {
    let info = nusb::list_devices()?
        .find(|info| info.vendor_id() == vendor_id && info.product_id() == product_id)
        .ok_or_else(|| {
            format!("USB device {vendor_id:04x}:{product_id:04x} is no longer connected")
        })?;
    let summary = discovery_device(&info);
    emit(&CaptureStarted {
        kind: "capture_started",
        schema_version: 1,
        timestamp_ms: now_ms(),
        device: summary.clone(),
        safety: "read-only vendor interfaces; microphone audio and serial numbers are not captured",
    });

    let device = info.open()?;
    let configuration = device.active_configuration()?;
    let mut candidates = Vec::new();
    for group in configuration.interfaces() {
        for alternate in group
            .alt_settings()
            .filter(|alternate| alternate.alternate_setting() == 0)
        {
            if alternate.class() != 0xff {
                continue;
            }
            if let Some(endpoint) = alternate.endpoints().find(|endpoint| {
                endpoint.direction() == Direction::In
                    && matches!(
                        endpoint.transfer_type(),
                        EndpointType::Bulk | EndpointType::Interrupt
                    )
            }) {
                candidates.push((
                    alternate.interface_number(),
                    endpoint.address(),
                    endpoint_type_name(endpoint.transfer_type()),
                ));
            }
        }
    }

    if candidates.is_empty() {
        return Err("No readable vendor-status endpoint was found. This receiver may expose only USB audio.".into());
    }

    let packet_count = Arc::new(AtomicUsize::new(0));
    let mut started = 0usize;
    for (interface_number, endpoint, transfer_type) in candidates {
        match device.detach_and_claim_interface(interface_number) {
            Ok(interface) => {
                started += 1;
                let packet_count = packet_count.clone();
                thread::spawn(move || loop {
                    if packet_count.load(Ordering::Relaxed) >= 2_000 {
                        emit(&CaptureNotice {
                            kind: "capture_limit",
                            timestamp_ms: now_ms(),
                            message: "Packet limit reached; stop and save the scan.".to_string(),
                        });
                        break;
                    }
                    let completion = if transfer_type == "bulk" {
                        future::block_on(interface.bulk_in(endpoint, RequestBuffer::new(1_024)))
                    } else {
                        future::block_on(
                            interface.interrupt_in(endpoint, RequestBuffer::new(1_024)),
                        )
                    };
                    if let Err(error) = completion.status {
                        emit(&CaptureNotice {
                            kind: "capture_error",
                            timestamp_ms: now_ms(),
                            message: format!(
                                "Interface {interface_number} endpoint 0x{endpoint:02x}: {error:?}"
                            ),
                        });
                        break;
                    }
                    packet_count.fetch_add(1, Ordering::Relaxed);
                    let mut data = completion.data;
                    let original_length = data.len();
                    let redacted_ascii_ranges = redact_ascii_runs(&mut data);
                    emit(&CapturePacket {
                        kind: "packet",
                        timestamp_ms: now_ms(),
                        interface: interface_number,
                        endpoint,
                        transfer_type,
                        length: original_length,
                        data_hex: hex_compact(&data),
                        redacted_ascii_ranges,
                    });
                });
            }
            Err(error) => emit(&CaptureNotice {
                kind: "capture_error",
                timestamp_ms: now_ms(),
                message: format!("Could not claim vendor interface {interface_number}: {error}"),
            }),
        }
    }

    if started == 0 {
        return Err("The receiver's vendor interface is busy. Quit other microphone control apps and retry.".into());
    }

    // The parent app terminates this helper when the contributor stops/saves.
    loop {
        thread::sleep(Duration::from_secs(60));
    }
}

fn redact_ascii_runs(data: &mut [u8]) -> Vec<[usize; 2]> {
    let mut ranges = Vec::new();
    let mut start = 0usize;
    while start < data.len() {
        if !(0x20..=0x7e).contains(&data[start]) {
            start += 1;
            continue;
        }
        let mut end = start + 1;
        while end < data.len() && (0x20..=0x7e).contains(&data[end]) {
            end += 1;
        }
        if end - start >= 6 {
            data[start..end].fill(0);
            ranges.push([start, end]);
        }
        start = end;
    }
    ranges
}

fn parse_usb_id(value: &str) -> Result<u16, Box<dyn std::error::Error>> {
    if let Some(hex) = value.strip_prefix("0x") {
        Ok(u16::from_str_radix(hex, 16)?)
    } else {
        Ok(value.parse()?)
    }
}

fn direction_name(direction: Direction) -> &'static str {
    match direction {
        Direction::In => "in",
        Direction::Out => "out",
    }
}

fn endpoint_type_name(endpoint_type: EndpointType) -> &'static str {
    match endpoint_type {
        EndpointType::Control => "control",
        EndpointType::Isochronous => "isochronous",
        EndpointType::Bulk => "bulk",
        EndpointType::Interrupt => "interrupt",
    }
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

fn hex_compact(data: &[u8]) -> String {
    data.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn emit<T: Serialize>(value: &T) {
    static OUTPUT: std::sync::OnceLock<Mutex<()>> = std::sync::OnceLock::new();
    let _guard = OUTPUT.get_or_init(|| Mutex::new(())).lock().unwrap();
    if let Ok(line) = serde_json::to_string(value) {
        println!("{line}");
        let _ = io::stdout().flush();
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--list-discovery-devices") => list_discovery_devices(),
        Some("--capture-discovery") => {
            let vendor_id = parse_usb_id(args.get(2).ok_or("Missing USB vendor id")?)?;
            let product_id = parse_usb_id(args.get(3).ok_or("Missing USB product id")?)?;
            capture_discovery(vendor_id, product_id)
        }
        Some(other) => Err(format!("Unknown argument: {other}").into()),
        None => monitor(),
    }
}

#[cfg(test)]
mod tests {
    use super::redact_ascii_runs;

    #[test]
    fn redacts_long_ascii_identifiers_without_touching_binary_state() {
        let mut packet = [
            0x55, 0x10, 0x04, b'X', b'S', b'P', b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8',
            0x01,
        ];
        let ranges = redact_ascii_runs(&mut packet);
        assert_eq!(ranges, vec![[3, 14]]);
        assert_eq!(&packet[..3], &[0x55, 0x10, 0x04]);
        assert!(packet[3..14].iter().all(|byte| *byte == 0));
        assert_eq!(packet[14], 0x01);
    }

    #[test]
    fn leaves_short_protocol_ascii_unchanged() {
        let mut packet = *b"\x55ABC\x01";
        assert!(redact_ascii_runs(&mut packet).is_empty());
        assert_eq!(&packet, b"\x55ABC\x01");
    }
}
