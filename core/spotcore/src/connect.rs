//! This Mac as a Spotify Connect device, run beside the local player
//! (ADR-009). `Spirc` gets its own session and player; the player shares
//! the local player's sink and mixer and plays only while Connect owns them.

use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use futures_util::StreamExt;
use http::header::{CONTENT_TYPE, HeaderValue};
use http::{HeaderMap, Method};
use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::config::DeviceType;
use librespot_core::dealer::manager::BoxedStreamResult;
use librespot_core::dealer::protocol::Message;
use librespot_core::{Session, SessionConfig};
use librespot_discovery::Discovery;
use librespot_protocol::connect::ClusterUpdate;
use log::{info, warn};
use tokio::sync::watch;

use crate::devices::{ConnectDevice, ConnectError, DeviceList, TransferPort};
use crate::player::{Epoch, PlaybackEvent, QueueSnapshot, SpotPlayer, lock, playable};
use crate::queue::RepeatMode;
use crate::reconnect::{Connector, Link, Supervisor};
use crate::remote::{
    Change, RemoteCommand, command_body, command_endpoint, remote_change, remote_playback,
    volume_body, volume_endpoint,
};
use crate::session::{
    CONNECT_TIMEOUT, ConnectivityFollower, SessionError, SpotSession, StoredCredentials,
    map_connect_error,
};

/// Fixed so the id is stable across launches and phones list one device.
const DEVICE_ID_SUFFIX: &str = "-connect";
const FALLBACK_NAME: &str = "Veya";
const CLUSTER_URI: &str = "hm://connect-state/v1/cluster";
/// How long Spirc gets to go inactive and unregister before its session closes.
const SPIRC_STOP_TIMEOUT: Duration = Duration::from_secs(3);

/// The Connect device id for the main session's `device_id`. Idempotent, as
/// reconnects pass back the Connect session's own credentials.
fn connect_device_id(device_id: &str) -> String {
    if device_id.ends_with(DEVICE_ID_SUFFIX) {
        device_id.to_owned()
    } else {
        format!("{device_id}{DEVICE_ID_SUFFIX}")
    }
}

fn device_name(name: &str) -> String {
    match name.trim() {
        "" => FALLBACK_NAME.to_owned(),
        name => name.to_owned(),
    }
}

/// Threat model: anyone on the LAN can send zeroconf credentials; only the
/// signed-in account's are accepted, so the app never switches accounts.
fn accepts_zeroconf(received: Option<&str>, signed_in: &str) -> bool {
    !signed_in.is_empty() && received == Some(signed_in)
}

/// The queue the cluster holds. Delimiters and page markers are skipped;
/// `autoplay` is the caller's, as the cluster does not carry it.
fn queue_snapshot(update: &ClusterUpdate, autoplay: bool) -> QueueSnapshot {
    let state = &update.cluster.player_state;
    let (up_next, next_from_context) = state
        .next_tracks
        .iter()
        .filter(|track| playable(&track.uri).is_ok())
        .partition::<Vec<_>, _>(|track| track.provider == "queue");
    let uris = |tracks: Vec<&librespot_protocol::player::ProvidedTrack>| {
        tracks.into_iter().map(|t| t.uri.clone()).collect()
    };
    let options = &state.options;
    QueueSnapshot {
        current: Some(state.track.uri.clone()).filter(|uri| !uri.is_empty()),
        up_next: uris(up_next),
        next_from_context: uris(next_from_context),
        shuffle: options.shuffling_context,
        repeat: if options.repeating_track {
            RepeatMode::Track
        } else if options.repeating_context {
            RepeatMode::Context
        } else {
            RepeatMode::Off
        },
        autoplay,
    }
}

/// Wire format of a connect-state `add_to_queue` command, as Spotify's
/// clients send it; the server adds `message_id` and `sent_by_device_id`.
fn add_to_queue_command(uri: &str) -> Vec<u8> {
    serde_json::json!({
        "command": {
            "endpoint": "add_to_queue",
            "track": {
                "uri": uri,
                "provider": "queue",
                "metadata": { "is_queued": "true" },
            },
            "logging_params": {},
        }
    })
    .to_string()
    .into_bytes()
}

/// Runs `close` once the Spirc task has ended, or after the timeout: Spirc
/// unregisters the device over its session, so closing first leaves phones
/// listing it.
async fn close_after_spirc(mut task_ended: watch::Receiver<bool>, close: impl FnOnce()) {
    let ended = tokio::time::timeout(SPIRC_STOP_TIMEOUT, task_ended.wait_for(|ended| *ended));
    if ended.await.is_err() {
        warn!("Spirc did not stop in time; closing its session");
    }
    close();
}

/// One registered Connect device: its session, Spirc and Spirc's player.
struct ConnectLink {
    session: Session,
    spirc: Spirc,
    /// Retired on shutdown, which silences Spirc's player and its events.
    epoch: Epoch,
    task_ended: watch::Receiver<bool>,
    /// True once the session is shut down, after Spirc unregistered.
    closed: Arc<watch::Sender<bool>>,
    shut: AtomicBool,
    runtime: tokio::runtime::Handle,
    player: Weak<SpotPlayer>,
    devices: ClusterDevices,
}

impl Link for ConnectLink {
    fn is_invalid(&self) -> bool {
        self.session.is_invalid() || *self.task_ended.borrow()
    }

    fn shutdown(&self) {
        if self.shut.swap(true, SeqCst) {
            return;
        }
        match self.player.upgrade() {
            Some(player) => {
                player.connect_retired(&self.epoch);
                // After the retire, so a racing cluster update cannot refill it.
                let mut list = lock(&self.devices);
                if list.remote.is_some() {
                    player.leave_remote(true);
                }
                if list.clear() {
                    player.emit(PlaybackEvent::DevicesChanged {
                        devices: Vec::new(),
                    });
                }
            }
            None => self.epoch.retire(),
        }
        // Fails only once the Spirc task has ended, which is the goal.
        let _ = self.spirc.shutdown();
        let session = self.session.clone();
        let closed = Arc::clone(&self.closed);
        self.runtime
            .spawn(close_after_spirc(self.task_ended.clone(), move || {
                session.shutdown();
                closed.send_replace(true);
            }));
    }

    fn stored_credentials(&self) -> Result<StoredCredentials, SessionError> {
        Link::stored_credentials(&self.session)
    }
}

type ClusterQueue = Arc<Mutex<Option<QueueSnapshot>>>;
type ClusterDevices = Arc<Mutex<DeviceList>>;

struct ConnectConnector {
    player: Arc<SpotPlayer>,
    name: String,
    queue: ClusterQueue,
    devices: ClusterDevices,
    /// The last link's `closed`, so a reconnect cannot be unregistered by
    /// the old link's late unregister for the same device id.
    previous: Mutex<Option<watch::Receiver<bool>>>,
}

impl Connector<ConnectLink> for ConnectConnector {
    async fn connect(&self, stored: StoredCredentials) -> Result<ConnectLink, SessionError> {
        let previous = lock(&self.previous).take();
        if let Some(mut closed) = previous {
            let _ = tokio::time::timeout(SPIRC_STOP_TIMEOUT, closed.wait_for(|c| *c)).await;
        }
        let config = SessionConfig {
            device_id: connect_device_id(&stored.device_id),
            ..SessionConfig::default()
        };
        // shortcut: no audio cache on this session, so Connect playback always
        // streams; hand SpotConnect the AudioCache if that costs too much data.
        let session = Session::new(config, None);
        let epoch = Epoch::default();
        let player = self
            .player
            .spawn_connect_player(session.clone(), epoch.clone());
        let connect_config = ConnectConfig {
            name: self.name.clone(),
            device_type: DeviceType::Computer,
            // Spirc applies this to the shared mixer; keep the app's volume.
            // shortcut: a reconnect re-applies the app's volume, not the one a
            // remote last set; carry Spirc's volume over if that is noticed.
            initial_volume: self.player.volume(),
            ..ConnectConfig::default()
        };
        // Before Spirc connects the session, so the first cluster push is not
        // missed; the dealer only pushes the cluster when it changes.
        match session
            .dealer()
            .listen_for(CLUSTER_URI, Message::from_raw::<ClusterUpdate>)
        {
            Ok(updates) => {
                tokio::spawn(follow_cluster(
                    updates,
                    Arc::downgrade(&self.player),
                    Arc::clone(&self.queue),
                    Arc::clone(&self.devices),
                    session.device_id().to_owned(),
                    epoch.clone(),
                ));
            }
            Err(e) => warn!("cannot follow the Connect cluster: {e}"),
        }
        let started = tokio::time::timeout(
            CONNECT_TIMEOUT,
            Spirc::new(
                connect_config,
                session.clone(),
                stored.credentials,
                player,
                self.player.connect_mixer(),
            ),
        )
        .await;
        let (spirc, task) = match started {
            Ok(Ok(started)) => started,
            failed => {
                epoch.retire();
                session.shutdown();
                return Err(match failed {
                    Ok(Err(e)) => map_connect_error(&e),
                    _ => SessionError::Network {
                        message: "connection timed out".to_owned(),
                    },
                });
            }
        };
        let (ended, task_ended) = watch::channel(false);
        tokio::spawn(async move {
            task.await;
            ended.send_replace(true);
        });
        info!("Connect device registered");
        let closed = Arc::new(watch::Sender::new(false));
        *lock(&self.previous) = Some(closed.subscribe());
        Ok(ConnectLink {
            session,
            spirc,
            epoch,
            task_ended,
            closed,
            shut: AtomicBool::new(false),
            runtime: tokio::runtime::Handle::current(),
            player: Arc::downgrade(&self.player),
            devices: Arc::clone(&self.devices),
        })
    }
}

/// Keeps the cluster's queue for Connect mode and its devices, and tells
/// the app they changed.
async fn follow_cluster(
    mut updates: BoxedStreamResult<ClusterUpdate>,
    player: Weak<SpotPlayer>,
    queue: ClusterQueue,
    devices: ClusterDevices,
    this_id: String,
    epoch: Epoch,
) {
    while let Some(update) = updates.next().await {
        if !epoch.is_current() {
            return;
        }
        let update = match update {
            Ok(update) => update,
            Err(e) => {
                warn!("unreadable Connect cluster update: {e}");
                continue;
            }
        };
        let queue_changed = {
            let mut queue = lock(&queue);
            let snapshot = Some(queue_snapshot(&update, false));
            let changed = *queue != snapshot;
            *queue = snapshot;
            changed
        };
        let Some(player) = player.upgrade() else {
            return;
        };
        let (devices, this_id, epoch) = (Arc::clone(&devices), this_id.clone(), epoch.clone());
        // This may hold the last reference, and dropping a player joins its thread.
        let _ = tokio::task::spawn_blocking(move || {
            apply_cluster(&devices, &update, &this_id, &epoch, queue_changed, &*player);
        })
        .await;
    }
}

/// What a cluster update tells the player; a seam for the lock order test.
pub(crate) trait ClusterSink {
    /// Must not take `SpotPlayer` locks: it runs under the device list lock.
    fn emit(&self, event: PlaybackEvent);
    fn apply_remote(&self, change: Change, events: Vec<PlaybackEvent>, epoch: &Epoch);
    fn queue_changed(&self, remote: bool);
}

/// Updates the device list and Remote mode under the list lock, then
/// applies the change after releasing it: `apply_remote` takes `state`,
/// which comes first in the lock order (see `SpotPlayer`).
fn apply_cluster(
    devices: &Mutex<DeviceList>,
    update: &ClusterUpdate,
    this_id: &str,
    epoch: &Epoch,
    queue_changed: bool,
    sink: &impl ClusterSink,
) {
    let (change, events, remote) = {
        // Checked under the list lock that link shutdown clears it under.
        let mut list = lock(devices);
        if !epoch.is_current() {
            return;
        }
        if list.update(update, this_id) {
            sink.emit(PlaybackEvent::DevicesChanged {
                devices: list.devices.clone(),
            });
        }
        let observed = remote_playback(update, this_id);
        let (change, next, events) = remote_change(list.remote.as_ref(), observed, &list.active);
        list.remote = next;
        (change, events, list.remote.is_some())
    };
    sink.apply_remote(change, events, epoch);
    if queue_changed {
        sink.queue_changed(remote);
    }
}

impl ClusterSink for SpotPlayer {
    fn emit(&self, event: PlaybackEvent) {
        SpotPlayer::emit(self, event);
    }

    fn apply_remote(&self, change: Change, events: Vec<PlaybackEvent>, epoch: &Epoch) {
        SpotPlayer::apply_remote(self, change, events, epoch);
    }

    fn queue_changed(&self, remote: bool) {
        SpotPlayer::queue_changed(self, remote);
    }
}

/// Advertises the device over Bonjour until `stop` changes or is dropped.
fn start_discovery(
    device_id: String,
    client_id: String,
    name: String,
    username: String,
) -> Option<watch::Sender<bool>> {
    let launched = Discovery::builder(device_id, client_id)
        .name(name)
        .device_type(DeviceType::Computer)
        .launch();
    let mut discovery = match launched {
        Ok(discovery) => discovery,
        Err(e) => {
            warn!("zeroconf unavailable: {e}");
            return None;
        }
    };
    let (stop, mut stopped) = watch::channel(false);
    tokio::spawn(async move {
        loop {
            tokio::select! {
                credentials = discovery.next() => match credentials {
                    // Spirc is already signed in as this account.
                    Some(c) if accepts_zeroconf(c.username.as_deref(), &username) => {
                        info!("zeroconf login from the signed-in account");
                    }
                    Some(_) => warn!("zeroconf login for another account dropped"),
                    None => break,
                },
                _ = stopped.changed() => break,
            }
        }
        discovery.shutdown().await;
        info!("zeroconf stopped");
    });
    Some(stop)
}

#[derive(uniffi::Object)]
pub struct SpotConnect {
    supervisor: Supervisor<ConnectLink>,
    queue: ClusterQueue,
    devices: ClusterDevices,
    player: Arc<SpotPlayer>,
    runtime: tokio::runtime::Handle,
    /// Dropping it stops zeroconf.
    _zeroconf: Option<watch::Sender<bool>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl SpotConnect {
    /// Registers this Mac as Connect device `name` on a second session for
    /// the signed-in account, beside `player`. `zeroconf` also advertises
    /// it on the LAN. To rename, shut this down and start another.
    #[uniffi::constructor]
    pub async fn start(
        session: Arc<SpotSession>,
        player: Arc<SpotPlayer>,
        name: String,
        zeroconf: bool,
    ) -> Result<Arc<Self>, SessionError> {
        let stored = session.stored()?;
        let device_id = connect_device_id(&stored.device_id);
        let name = device_name(&name);
        let queue = ClusterQueue::default();
        let devices = ClusterDevices::default();
        let connector = ConnectConnector {
            player: Arc::clone(&player),
            name: name.clone(),
            queue: Arc::clone(&queue),
            devices: Arc::clone(&devices),
            previous: Mutex::default(),
        };
        let link = connector.connect(stored.clone()).await?;
        let zeroconf = zeroconf
            .then(|| {
                let main = session.current_session();
                start_discovery(device_id, main.client_id(), name, main.username())
            })
            .flatten();
        let this = Arc::new(Self {
            supervisor: Supervisor::start(link, stored, connector),
            queue,
            devices,
            player: Arc::clone(&player),
            runtime: tokio::runtime::Handle::current(),
            _zeroconf: zeroconf,
        });
        player.attach_connect(Arc::downgrade(&this));
        let follower: Weak<dyn ConnectivityFollower> = Arc::downgrade(&this) as _;
        session.set_follower(follower);
        Ok(this)
    }

    /// Hands the sink back to the local player and returns once the device
    /// is unregistered and its session closed, so a restart with the same id
    /// cannot be unregistered late. Idempotent.
    pub async fn shutdown(&self) {
        self.supervisor.shutdown();
        let mut closed = self.supervisor.current_link().closed.subscribe();
        let _ = closed.wait_for(|closed| *closed).await;
    }

    /// Moves playback, with its position and queue, to the online device
    /// `device_id`. Leaving this Mac's local playback pauses it, as Spotify
    /// does not hold the local queue (ADR-009).
    pub async fn transfer(&self, device_id: String) -> Result<(), ConnectError> {
        let link = self.supervisor.current_link();
        let port = LivePort {
            link: &link,
            player: &self.player,
        };
        crate::devices::transfer(&self.devices, link.session.device_id(), device_id, &port).await
    }
}

struct LivePort<'a> {
    link: &'a ConnectLink,
    player: &'a SpotPlayer,
}

impl TransferPort for LivePort<'_> {
    fn to_this_mac(&self) -> Result<(), String> {
        self.link.spirc.transfer(None).map_err(|e| e.to_string())
    }

    async fn between(&self, from: &str, to: &str) -> Result<(), String> {
        let spclient = self.link.session.spclient();
        spclient
            .transfer(from, to, None)
            .await
            .map(drop)
            .map_err(|e| e.to_string())
    }

    fn pause_local(&self) {
        self.player.pause_local();
    }

    fn devices_changed(&self, devices: Vec<ConnectDevice>) {
        self.player.emit(PlaybackEvent::DevicesChanged { devices });
    }
}

impl ConnectivityFollower for SpotConnect {
    fn system_did_wake(&self) {
        self.supervisor.reconnect_now();
    }

    fn network_changed(&self, available: bool) {
        self.supervisor.network_changed(available);
    }
}

impl SpotConnect {
    pub(crate) fn spirc(&self, command: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>) {
        if let Err(e) = command(&self.supervisor.current_link().spirc) {
            warn!("Connect command failed: {e}");
        }
    }

    pub(crate) fn queue(&self, autoplay: bool) -> QueueSnapshot {
        lock(&self.queue)
            .clone()
            .map(|snapshot| QueueSnapshot {
                autoplay,
                ..snapshot
            })
            .unwrap_or(QueueSnapshot {
                current: None,
                up_next: Vec::new(),
                next_from_context: Vec::new(),
                shuffle: false,
                repeat: RepeatMode::Off,
                autoplay,
            })
    }

    /// Sends Spirc an `add_to_queue` command through Spotify, as Spirc's
    /// handle has no queue API (ADR-009).
    pub(crate) fn add_to_queue(&self, uri: String) {
        self.send(
            Method::POST,
            None,
            add_to_queue_command(&uri),
            command_endpoint,
        );
    }

    /// Runs `f` under the device list lock; it must not call back into a
    /// `SpotPlayer` method that takes `state` or `player`.
    pub(crate) fn with_devices<R>(&self, f: impl FnOnce(&DeviceList) -> R) -> R {
        f(&lock(&self.devices))
    }

    /// Stops following a paused remote, so a local load plays here; false
    /// when it is playing or there is none.
    pub(crate) fn leave_paused_remote(&self) -> bool {
        let mut list = lock(&self.devices);
        if list.remote.as_ref().is_some_and(|r| !r.playing) {
            list.remote = None;
            return true;
        }
        false
    }

    pub(crate) fn remote(&self, target: String, command: &RemoteCommand) {
        self.send(
            Method::POST,
            Some(target),
            command_body(command),
            command_endpoint,
        );
    }

    pub(crate) fn remote_add_to_queue(&self, target: String, uri: &str) {
        let body = add_to_queue_command(uri);
        self.send(Method::POST, Some(target), body, command_endpoint);
    }

    // shortcut: the volume request's method and body follow Spotify's web
    // client and are unverified; check them with a real device.
    pub(crate) fn remote_volume(&self, target: String, volume: u16) {
        self.send(
            Method::PUT,
            Some(target),
            volume_body(volume),
            volume_endpoint,
        );
    }

    /// Sends a JSON connect-state request from this device to `target`, or
    /// to itself when `None`.
    fn send(
        &self,
        method: Method,
        target: Option<String>,
        body: Vec<u8>,
        endpoint: fn(&str, &str) -> String,
    ) {
        let session = self.supervisor.current_link().session.clone();
        self.runtime.spawn(async move {
            let me = session.device_id().to_owned();
            let endpoint = endpoint(&me, target.as_deref().unwrap_or(&me));
            let mut headers = HeaderMap::new();
            headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
            let sent = session
                .spclient()
                .request(&method, &endpoint, Some(headers), Some(&body))
                .await;
            if let Err(e) = sent {
                warn!("Connect command failed: {e}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_core::dealer::protocol::{Command, Request};
    use librespot_protocol::connect::Cluster;
    use librespot_protocol::player::{ContextPlayerOptions, PlayerState, ProvidedTrack};

    /// Fails if the remote change is applied while the device list is
    /// locked, which deadlocked against `SpotPlayer::queue`.
    struct LockChecker<'a> {
        devices: &'a Mutex<DeviceList>,
        applied: Mutex<Vec<Change>>,
    }

    impl ClusterSink for LockChecker<'_> {
        fn emit(&self, _: PlaybackEvent) {}

        fn apply_remote(&self, change: Change, _: Vec<PlaybackEvent>, _: &Epoch) {
            assert!(
                self.devices.try_lock().is_ok(),
                "applied under the list lock"
            );
            self.applied.lock().unwrap().push(change);
        }

        fn queue_changed(&self, _: bool) {
            assert!(self.devices.try_lock().is_ok());
        }
    }

    #[test]
    fn a_remote_change_is_applied_after_the_device_list_is_released() {
        let mut state = PlayerState {
            track: Some(ProvidedTrack {
                uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQA".to_owned(),
                ..Default::default()
            })
            .into(),
            is_playing: true,
            ..Default::default()
        };
        state.duration = 1_000;
        let update = ClusterUpdate {
            cluster: Some(Cluster {
                active_device_id: "phone".to_owned(),
                player_state: Some(state).into(),
                ..Default::default()
            })
            .into(),
            ..Default::default()
        };
        let devices = Mutex::new(DeviceList::default());
        let checker = LockChecker {
            devices: &devices,
            applied: Mutex::default(),
        };

        apply_cluster(&devices, &update, "mac", &Epoch::default(), true, &checker);

        assert_eq!(*checker.applied.lock().unwrap(), [Change::Enter]);
        assert!(lock(&devices).remote.is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn session_closes_only_after_spirc_has_unregistered() {
        let (ended, task_ended) = watch::channel(false);
        let closed = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&closed);
        let closing = tokio::spawn(close_after_spirc(task_ended, move || {
            flag.store(true, SeqCst);
        }));
        tokio::time::sleep(SPIRC_STOP_TIMEOUT / 2).await;
        assert!(
            !closed.load(SeqCst),
            "closed while Spirc was still unregistering"
        );

        ended.send_replace(true);
        closing.await.unwrap();
        assert!(closed.load(SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn a_stuck_spirc_does_not_keep_its_session_open() {
        let (_ended, task_ended) = watch::channel(false);
        let closed = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&closed);
        close_after_spirc(task_ended, move || flag.store(true, SeqCst)).await;
        assert!(closed.load(SeqCst));
    }

    #[test]
    fn connect_device_id_appends_a_fixed_suffix_once() {
        let id = connect_device_id("abc123");
        assert_eq!(id, "abc123-connect");
        assert_eq!(
            connect_device_id(&id),
            id,
            "a reconnect must not grow the id"
        );
        assert_eq!(connect_device_id("abc123"), id, "stable across launches");
    }

    #[test]
    fn device_name_falls_back_when_blank() {
        assert_eq!(device_name("  Kitchen Mac "), "Kitchen Mac");
        assert_eq!(device_name(""), FALLBACK_NAME);
        assert_eq!(device_name(" \t"), FALLBACK_NAME);
    }

    #[test]
    fn zeroconf_accepts_only_the_signed_in_account() {
        assert!(accepts_zeroconf(Some("me"), "me"));
        assert!(!accepts_zeroconf(Some("someone"), "me"));
        assert!(!accepts_zeroconf(Some("ME"), "me"), "no case folding");
        assert!(!accepts_zeroconf(None, "me"));
        assert!(
            !accepts_zeroconf(Some(""), ""),
            "unknown user accepts nobody"
        );
    }

    fn provided(uri: &str, provider: &str) -> ProvidedTrack {
        ProvidedTrack {
            uri: uri.to_owned(),
            provider: provider.to_owned(),
            ..Default::default()
        }
    }

    #[test]
    fn queue_snapshot_splits_queued_tracks_from_the_context() {
        let a = "spotify:track:4uLU6hMCjMI75M1A2tKUQA";
        let b = "spotify:track:4uLU6hMCjMI75M1A2tKUQB";
        let c = "spotify:episode:4uLU6hMCjMI75M1A2tKUQC";
        let state = PlayerState {
            track: Some(provided(a, "context")).into(),
            next_tracks: vec![
                provided(b, "queue"),
                provided("spotify:delimiter", "context"),
                provided(c, "context"),
                provided(a, "autoplay"),
            ],
            options: Some(ContextPlayerOptions {
                shuffling_context: true,
                repeating_context: true,
                ..Default::default()
            })
            .into(),
            ..Default::default()
        };
        let update = ClusterUpdate {
            cluster: Some(Cluster {
                player_state: Some(state).into(),
                ..Default::default()
            })
            .into(),
            ..Default::default()
        };
        assert_eq!(
            queue_snapshot(&update, true),
            QueueSnapshot {
                current: Some(a.to_owned()),
                up_next: vec![b.to_owned()],
                next_from_context: vec![c.to_owned(), a.to_owned()],
                shuffle: true,
                repeat: RepeatMode::Context,
                autoplay: true,
            }
        );
    }

    #[test]
    fn queue_snapshot_of_an_empty_cluster_is_empty() {
        let snapshot = queue_snapshot(&ClusterUpdate::default(), false);
        assert_eq!(snapshot.current, None);
        assert!(snapshot.up_next.is_empty() && snapshot.next_from_context.is_empty());
        assert_eq!(snapshot.repeat, RepeatMode::Off);
    }

    #[test]
    fn add_to_queue_command_parses_as_spirc_reads_it() {
        let uri = "spotify:track:4uLU6hMCjMI75M1A2tKUQA";
        let mut delivered: serde_json::Value =
            serde_json::from_slice(&add_to_queue_command(uri)).unwrap();
        delivered["message_id"] = 1.into();
        delivered["sent_by_device_id"] = "abc-connect".into();
        let request: Request = serde_json::from_value(delivered).unwrap();
        let Command::AddToQueue(command) = request.command else {
            panic!("not add_to_queue: {}", request.command);
        };
        assert_eq!(command.track.uri, uri);
        assert_eq!(command.track.provider, "queue");
    }
}
