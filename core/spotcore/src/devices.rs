//! The account's Connect devices from cluster updates, and where a transfer
//! goes (ADR-009 "Cluster and devices", PBI-502).

use std::sync::{Arc, Mutex};

use librespot_protocol::connect::ClusterUpdate;
use librespot_protocol::devices::DeviceType;

use crate::util::lock;

/// Messages never carry tokens or usernames.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ConnectError {
    #[error("no Connect device {id} is online")]
    UnknownDevice { id: String },
    #[error("transfer failed: {message}")]
    Transfer { message: String },
}

/// Device types grouped by the icon the app shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeviceKind {
    Computer,
    Smartphone,
    Tablet,
    Speaker,
    Tv,
    Car,
    GameConsole,
    Watch,
    Other,
}

impl From<DeviceType> for DeviceKind {
    fn from(device_type: DeviceType) -> Self {
        use DeviceType as T;
        match device_type {
            T::COMPUTER | T::CHROMEBOOK => Self::Computer,
            T::SMARTPHONE => Self::Smartphone,
            T::TABLET => Self::Tablet,
            T::SPEAKER | T::AVR | T::AUDIO_DONGLE | T::CAST_AUDIO | T::HOME_THING => Self::Speaker,
            T::TV | T::STB | T::CAST_VIDEO => Self::Tv,
            T::AUTOMOBILE | T::CAR_THING => Self::Car,
            T::GAME_CONSOLE => Self::GameConsole,
            T::SMARTWATCH => Self::Watch,
            T::UNKNOWN | T::UNKNOWN_SPOTIFY | T::OBSERVER => Self::Other,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConnectDevice {
    pub id: String,
    pub name: String,
    pub kind: DeviceKind,
    /// 0..=65535, like `SpotPlayer::set_volume`.
    pub volume: u16,
    pub is_active: bool,
    /// This Mac's Connect device; the app names it "This Mac".
    pub is_this_device: bool,
}

/// The cluster's devices playback can move to: this Mac first, then by
/// name. Offline, hidden, uncontrollable and play-incapable ones are left out.
pub(crate) fn connect_devices(update: &ClusterUpdate, this_id: &str) -> Vec<ConnectDevice> {
    let cluster = &update.cluster;
    let mut devices: Vec<_> = cluster
        .device
        .iter()
        .filter(|(_, info)| {
            let capabilities = &info.capabilities;
            info.can_play
                && !info.is_offline
                && !capabilities.hidden
                && capabilities.is_controllable
        })
        .map(|(id, info)| ConnectDevice {
            id: id.clone(),
            name: info.name.clone(),
            kind: info
                .device_type
                .enum_value()
                .map_or(DeviceKind::Other, DeviceKind::from),
            volume: u16::try_from(info.volume).unwrap_or(u16::MAX),
            is_active: *id == cluster.active_device_id,
            is_this_device: id == this_id,
        })
        .collect();
    devices.sort_by_cached_key(|d| (!d.is_this_device, d.name.to_lowercase(), d.id.clone()));
    devices
}

/// How playback moves to a device.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Transfer {
    /// The target is already playing.
    Stay,
    /// `Spirc::transfer`, which with nothing active resumes the account's
    /// last session on this Mac.
    ToThisMac,
    /// `SpClient::transfer(from, to)`. With nothing active `from` is this
    /// Mac's device, so Spotify resumes the last session on the target.
    // shortcut: that nothing-active fallback is unverified against Spotify;
    // check it with a real device before relying on it.
    Between { from: String, to: String },
}

pub(crate) fn transfer_plan(active: Option<&str>, this_id: &str, target: &str) -> Transfer {
    let active = active.filter(|id| !id.is_empty());
    if active == Some(target) {
        Transfer::Stay
    } else if target == this_id {
        Transfer::ToThisMac
    } else {
        Transfer::Between {
            from: active.unwrap_or(this_id).to_owned(),
            to: target.to_owned(),
        }
    }
}

/// The last cluster's devices and active device id ("" when none).
#[derive(Default)]
pub(crate) struct DeviceList {
    pub(crate) devices: Vec<ConnectDevice>,
    pub(crate) active: String,
    /// The active remote device's playback while in Remote mode (PBI-503).
    pub(crate) remote: Option<crate::remote::RemotePlayback>,
    /// Bumped by every change, so a snapshot reported late loses to a newer one.
    version: u64,
    reported: Arc<Mutex<u64>>,
}

/// A device list taken under the list lock, reported after it is released.
pub(crate) struct Listed {
    devices: Vec<ConnectDevice>,
    version: u64,
    reported: Arc<Mutex<u64>>,
}

impl Listed {
    /// Calls `emit` unless a newer list was already reported. Holds the
    /// report lock across `emit`, so `emit` must not report a list itself.
    pub(crate) fn report(self, emit: impl FnOnce(Vec<ConnectDevice>)) {
        let mut last = lock(&self.reported);
        if self.version > *last {
            *last = self.version;
            emit(self.devices);
        }
    }
}

impl DeviceList {
    /// Returns whether the list or the active device changed.
    pub(crate) fn update(&mut self, update: &ClusterUpdate, this_id: &str) -> bool {
        let devices = connect_devices(update, this_id);
        let active = &update.cluster.active_device_id;
        let changed = devices != self.devices || *active != self.active;
        self.devices = devices;
        self.active.clone_from(active);
        changed
    }

    /// Marks `id` active ahead of the cluster update confirming it, so a
    /// quick second transfer starts from the right device.
    fn set_active(&mut self, id: &str) -> bool {
        if self.active == id {
            return false;
        }
        id.clone_into(&mut self.active);
        for device in &mut self.devices {
            device.is_active = device.id == id;
        }
        true
    }

    /// Returns whether anything was listed.
    pub(crate) fn clear(&mut self) -> bool {
        let listed = !self.devices.is_empty();
        *self = Self {
            version: self.version,
            reported: Arc::clone(&self.reported),
            ..Self::default()
        };
        listed
    }

    /// Call after a change, under the list lock, to report it once released.
    pub(crate) fn changed(&mut self) -> Listed {
        self.version += 1;
        Listed {
            devices: self.devices.clone(),
            version: self.version,
            reported: Arc::clone(&self.reported),
        }
    }

    pub(crate) fn contains(&self, id: &str) -> bool {
        self.devices.iter().any(|d| d.id == id)
    }
}

/// What a transfer does outside the device list: a seam over `Spirc`,
/// `SpClient` and the local player.
pub(crate) trait TransferPort: Send + Sync {
    fn to_this_mac(&self) -> Result<(), String>;
    fn between(&self, from: &str, to: &str) -> impl Future<Output = Result<(), String>> + Send;
    fn pause_local(&self);
    /// Gets the list after a transfer moved the active mark, with the list
    /// lock released.
    fn devices_changed(&self, devices: Vec<ConnectDevice>);
}

/// Moves playback to the listed device `target`. Leaving this Mac's local
/// playback pauses it, as Spotify does not hold the local queue (ADR-009).
pub(crate) async fn transfer(
    list: &Mutex<DeviceList>,
    this_id: &str,
    target: String,
    port: &impl TransferPort,
) -> Result<(), ConnectError> {
    let plan = {
        let list = lock(list);
        if !list.contains(&target) {
            return Err(ConnectError::UnknownDevice { id: target });
        }
        transfer_plan(Some(&list.active), this_id, &target)
    };
    let failed = |message| ConnectError::Transfer { message };
    match plan {
        Transfer::Stay => return Ok(()),
        Transfer::ToThisMac => port.to_this_mac().map_err(failed)?,
        Transfer::Between { from, to } => {
            port.between(&from, &to).await.map_err(failed)?;
            port.pause_local();
        }
    }
    let changed = {
        let mut list = lock(list);
        list.set_active(&target).then(|| list.changed())
    };
    // The observer may call back into the device list.
    if let Some(listed) = changed {
        listed.report(|devices| port.devices_changed(devices));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_protocol::connect::{Capabilities, Cluster, DeviceInfo};

    fn info(name: &str, device_type: DeviceType, volume: u32) -> DeviceInfo {
        DeviceInfo {
            name: name.to_owned(),
            device_type: device_type.into(),
            volume,
            can_play: true,
            capabilities: Some(Capabilities {
                is_controllable: true,
                ..Default::default()
            })
            .into(),
            ..Default::default()
        }
    }

    fn update(devices: Vec<(&str, DeviceInfo)>, active: &str) -> ClusterUpdate {
        ClusterUpdate {
            cluster: Some(Cluster {
                device: devices
                    .into_iter()
                    .map(|(id, info)| (id.to_owned(), info))
                    .collect(),
                active_device_id: active.to_owned(),
                ..Default::default()
            })
            .into(),
            ..Default::default()
        }
    }

    #[test]
    fn cluster_maps_to_devices_with_this_mac_first() {
        let offline = DeviceInfo {
            is_offline: true,
            ..info("Old iPad", DeviceType::TABLET, 0)
        };
        let mute = DeviceInfo {
            can_play: false,
            ..info("Remote", DeviceType::SMARTPHONE, 0)
        };
        let hidden = DeviceInfo {
            capabilities: Some(Capabilities {
                hidden: true,
                is_controllable: true,
                ..Default::default()
            })
            .into(),
            ..info("Hidden", DeviceType::SPEAKER, 0)
        };
        let locked = DeviceInfo {
            capabilities: Some(Capabilities::default()).into(),
            ..info("Locked", DeviceType::SPEAKER, 0)
        };
        let update = update(
            vec![
                ("phone", info("Pixel", DeviceType::SMARTPHONE, 65_535)),
                (
                    "mac-connect",
                    info("Studio Mac", DeviceType::COMPUTER, 32_768),
                ),
                ("speaker", info("Kitchen", DeviceType::CAST_AUDIO, 70_000)),
                ("ipad", offline),
                ("remote", mute),
                ("hidden", hidden),
                ("locked", locked),
            ],
            "phone",
        );

        let devices = connect_devices(&update, "mac-connect");

        assert_eq!(
            devices,
            [
                ConnectDevice {
                    id: "mac-connect".to_owned(),
                    name: "Studio Mac".to_owned(),
                    kind: DeviceKind::Computer,
                    volume: 32_768,
                    is_active: false,
                    is_this_device: true,
                },
                ConnectDevice {
                    id: "speaker".to_owned(),
                    name: "Kitchen".to_owned(),
                    kind: DeviceKind::Speaker,
                    volume: u16::MAX,
                    is_active: false,
                    is_this_device: false,
                },
                ConnectDevice {
                    id: "phone".to_owned(),
                    name: "Pixel".to_owned(),
                    kind: DeviceKind::Smartphone,
                    volume: u16::MAX,
                    is_active: true,
                    is_this_device: false,
                },
            ]
        );
        let mut list = DeviceList::default();
        assert!(list.update(&update, "mac-connect"));
        assert_eq!(list.active, "phone");
        assert!(list.contains("speaker") && !list.contains("ipad"));
        assert!(!list.update(&update, "mac-connect"), "nothing changed");
        assert!(list.clear(), "a shut-down link empties the picker");
        assert!(list.devices.is_empty() && list.active.is_empty());
        assert!(!list.clear(), "an empty list is not announced again");
    }

    #[test]
    fn an_empty_cluster_has_no_devices_and_nothing_active() {
        let devices = connect_devices(&ClusterUpdate::default(), "mac-connect");
        assert!(devices.is_empty());
        let mut list = DeviceList::default();
        list.update(&ClusterUpdate::default(), "mac-connect");
        assert_eq!(list.active, "", "nothing active");
    }

    #[test]
    fn device_types_map_to_icon_groups() {
        assert_eq!(
            DeviceKind::from(DeviceType::CHROMEBOOK),
            DeviceKind::Computer
        );
        assert_eq!(DeviceKind::from(DeviceType::STB), DeviceKind::Tv);
        assert_eq!(DeviceKind::from(DeviceType::CAR_THING), DeviceKind::Car);
        assert_eq!(DeviceKind::from(DeviceType::OBSERVER), DeviceKind::Other);
    }

    #[test]
    fn transfer_to_this_mac_goes_through_spirc() {
        assert_eq!(
            transfer_plan(Some("phone"), "mac", "mac"),
            Transfer::ToThisMac
        );
        assert_eq!(
            transfer_plan(None, "mac", "mac"),
            Transfer::ToThisMac,
            "with nothing active Spirc resumes the last session here"
        );
    }

    #[test]
    fn transfer_elsewhere_moves_from_the_active_device() {
        assert_eq!(
            transfer_plan(Some("phone"), "mac", "speaker"),
            Transfer::Between {
                from: "phone".to_owned(),
                to: "speaker".to_owned()
            }
        );
        assert_eq!(
            transfer_plan(Some("mac"), "mac", "speaker"),
            Transfer::Between {
                from: "mac".to_owned(),
                to: "speaker".to_owned()
            }
        );
    }

    #[test]
    fn transfer_with_nothing_active_starts_from_this_mac() {
        for active in [None, Some("")] {
            assert_eq!(
                transfer_plan(active, "mac", "speaker"),
                Transfer::Between {
                    from: "mac".to_owned(),
                    to: "speaker".to_owned()
                }
            );
        }
    }

    #[test]
    fn transfer_to_the_active_device_stays() {
        assert_eq!(transfer_plan(Some("phone"), "mac", "phone"), Transfer::Stay);
        assert_eq!(transfer_plan(Some("mac"), "mac", "mac"), Transfer::Stay);
    }
}

#[cfg(test)]
mod transfer_tests {
    use super::*;
    use std::sync::Mutex;

    /// Records what a transfer did; `fails` makes the request fail.
    #[derive(Default)]
    struct Port {
        fails: bool,
        calls: Mutex<Vec<String>>,
    }

    impl Port {
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }

        fn record(&self, call: String) {
            self.calls.lock().unwrap().push(call);
        }
    }

    impl TransferPort for Port {
        fn to_this_mac(&self) -> Result<(), String> {
            self.record("spirc".to_owned());
            if self.fails {
                Err("down".to_owned())
            } else {
                Ok(())
            }
        }

        async fn between(&self, from: &str, to: &str) -> Result<(), String> {
            self.record(format!("{from}->{to}"));
            if self.fails {
                Err("down".to_owned())
            } else {
                Ok(())
            }
        }

        fn pause_local(&self) {
            self.record("pause".to_owned());
        }

        fn devices_changed(&self, devices: Vec<ConnectDevice>) {
            let active: Vec<_> = devices
                .iter()
                .filter(|d| d.is_active)
                .map(|d| d.id.clone())
                .collect();
            self.record(format!("active {}", active.join(",")));
        }
    }

    fn device(id: &str, active: &str) -> ConnectDevice {
        ConnectDevice {
            id: id.to_owned(),
            name: id.to_owned(),
            kind: DeviceKind::Speaker,
            volume: 0,
            is_active: id == active,
            is_this_device: id == "mac",
        }
    }

    fn list(active: &str) -> Mutex<DeviceList> {
        Mutex::new(DeviceList {
            devices: ["mac", "phone", "speaker"]
                .map(|id| device(id, active))
                .to_vec(),
            active: active.to_owned(),
            ..DeviceList::default()
        })
    }

    #[test]
    fn a_list_reported_late_loses_to_a_newer_one() {
        let devices = list("phone");
        let stale = lock(&devices).changed();
        let newer = {
            let mut list = lock(&devices);
            list.clear();
            list.changed()
        };
        let reported = Mutex::new(Vec::new());
        newer.report(|d| reported.lock().unwrap().push(d.len()));
        stale.report(|d| reported.lock().unwrap().push(d.len()));
        assert_eq!(*reported.lock().unwrap(), [0], "the cleared list stands");

        let after = lock(&devices).changed();
        after.report(|d| reported.lock().unwrap().push(d.len()));
        assert_eq!(
            reported.lock().unwrap().len(),
            2,
            "a clear keeps the version"
        );
    }

    /// Fails if the observer is told while the device list is locked.
    struct Reentrant<'a>(&'a Mutex<DeviceList>);

    impl TransferPort for Reentrant<'_> {
        fn to_this_mac(&self) -> Result<(), String> {
            Ok(())
        }

        async fn between(&self, _: &str, _: &str) -> Result<(), String> {
            Ok(())
        }

        fn pause_local(&self) {}

        fn devices_changed(&self, _: Vec<ConnectDevice>) {
            assert!(self.0.try_lock().is_ok(), "told under the list lock");
        }
    }

    #[tokio::test]
    async fn the_new_list_is_reported_after_the_lock_is_released() {
        let devices = list("phone");
        transfer(&devices, "mac", "speaker".to_owned(), &Reentrant(&devices))
            .await
            .unwrap();
        assert_eq!(lock(&devices).active, "speaker");
    }

    #[tokio::test]
    async fn an_unknown_device_is_rejected_without_a_request() {
        let port = Port::default();
        let result = transfer(&list("phone"), "mac", "gone".to_owned(), &port).await;
        assert!(matches!(result, Err(ConnectError::UnknownDevice { id }) if id == "gone"));
        assert!(port.calls().is_empty());
    }

    #[tokio::test]
    async fn a_failed_request_keeps_local_playback_and_the_active_device() {
        let port = Port {
            fails: true,
            ..Default::default()
        };
        let devices = list("");
        let result = transfer(&devices, "mac", "speaker".to_owned(), &port).await;
        assert!(matches!(result, Err(ConnectError::Transfer { .. })));
        assert_eq!(port.calls(), ["mac->speaker"], "no pause after a failure");
        assert_eq!(lock(&devices).active, "");
    }

    #[tokio::test]
    async fn moving_away_pauses_local_playback_and_marks_the_target() {
        let port = Port::default();
        let devices = list("");
        transfer(&devices, "mac", "speaker".to_owned(), &port)
            .await
            .unwrap();
        assert_eq!(port.calls(), ["mac->speaker", "pause", "active speaker"]);

        transfer(&devices, "mac", "phone".to_owned(), &port)
            .await
            .unwrap();
        assert_eq!(
            port.calls()[3],
            "speaker->phone",
            "a quick second transfer starts from the new active device"
        );
    }

    #[tokio::test]
    async fn moving_to_this_mac_goes_through_spirc_without_pausing() {
        let port = Port::default();
        let devices = list("phone");
        transfer(&devices, "mac", "mac".to_owned(), &port)
            .await
            .unwrap();
        assert_eq!(port.calls(), ["spirc", "active mac"]);
        assert_eq!(lock(&devices).active, "mac");
    }

    #[tokio::test]
    async fn choosing_the_active_device_does_nothing() {
        let port = Port::default();
        transfer(&list("phone"), "mac", "phone".to_owned(), &port)
            .await
            .unwrap();
        assert!(port.calls().is_empty());
    }
}
