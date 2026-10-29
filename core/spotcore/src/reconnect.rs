//! Keeps an access-point session alive: detects a dead session, reconnects
//! with stored credentials on the same device id, and reports progress.

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use log::{info, warn};
use tokio::sync::{Notify, watch};

use crate::session::{SessionError, StoredCredentials};
use crate::util::lock;

const POLL_INTERVAL: Duration = Duration::from_secs(1);
const MAX_BACKOFF_SECS: u32 = 60;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    Connected,
    /// `attempt` numbers the upcoming or in-flight reconnect attempt and
    /// starts at 1; `retry_in_secs` is the wait before it, 0 once it runs.
    Reconnecting {
        attempt: u32,
        retry_in_secs: u32,
    },
    /// Terminal: the AP refused the stored credentials; no more attempts.
    CredentialsRejected,
}

/// Implemented in Swift. Called on arbitrary Rust threads, without a lock
/// held, so the callback may call back into the session; must not block.
/// A call already under way may still finish after `shutdown` returns.
#[uniffi::export(with_foreign)]
pub trait ConnectionObserver: Send + Sync {
    fn on_state_changed(&self, state: ConnectionState);
}

/// Exponential reconnect delays: 1, 2, 4 ... 32, then 60 s forever.
#[derive(Debug, Default)]
pub(crate) struct Backoff {
    failures: u32,
}

impl Backoff {
    pub(crate) fn next_delay(&mut self) -> Duration {
        let secs = 1u32
            .checked_shl(self.failures)
            .map_or(MAX_BACKOFF_SECS, |s| s.min(MAX_BACKOFF_SECS));
        self.failures = self.failures.saturating_add(1);
        Duration::from_secs(secs.into())
    }

    pub(crate) fn reset(&mut self) {
        self.failures = 0;
    }
}

/// One live connection to the AP. Once invalid it is never valid again.
pub(crate) trait Link: Send + Sync + 'static {
    fn is_invalid(&self) -> bool;
    /// Must be idempotent.
    fn shutdown(&self);
    fn stored_credentials(&self) -> Result<StoredCredentials, SessionError>;
}

pub(crate) trait Connector<L: Link>: Send + Sync + 'static {
    fn connect(
        &self,
        credentials: StoredCredentials,
    ) -> impl Future<Output = Result<L, SessionError>> + Send;
}

struct Core<L> {
    link: Arc<L>,
    /// Reusable credentials once any session yielded them; until then the
    /// ones the first connect used.
    credentials: StoredCredentials,
    reusable: bool,
    shut_down: bool,
    wake: bool,
    retry_now: bool,
}

/// Guards state and observer only; the observer is called after the lock is
/// released so a callback can call `shutdown` or `set_observer`.
struct Reporter {
    state: ConnectionState,
    observer: Option<Arc<dyn ConnectionObserver>>,
    closed: bool,
}

struct Shared<L> {
    core: Mutex<Core<L>>,
    reporter: Mutex<Reporter>,
    nudge: Notify,
    stopped: watch::Sender<bool>,
    /// Counts links installed by reconnects; the first link is 0.
    links: watch::Sender<u64>,
}

impl<L: Link> Shared<L> {
    fn emit(&self, state: ConnectionState) {
        let observer = {
            let mut reporter = lock(&self.reporter);
            if reporter.closed {
                return;
            }
            match &state {
                ConnectionState::Connected => info!("session reconnected"),
                ConnectionState::Reconnecting {
                    attempt,
                    retry_in_secs,
                } => info!("reconnecting: attempt {attempt}, retry in {retry_in_secs} s"),
                ConnectionState::CredentialsRejected => {
                    warn!("reconnect stopped: stored credentials rejected")
                }
            }
            reporter.state = state.clone();
            reporter.observer.clone()
        };
        if let Some(observer) = observer {
            observer.on_state_changed(state);
        }
    }

    fn is_shut_down(&self) -> bool {
        lock(&self.core).shut_down
    }

    fn current_link(&self) -> Arc<L> {
        Arc::clone(&lock(&self.core).link)
    }

    /// Returns false when shutdown won the race; the new link is then closed.
    fn install(&self, link: L) -> bool {
        let mut core = lock(&self.core);
        if core.shut_down {
            drop(core);
            link.shutdown();
            return false;
        }
        match link.stored_credentials() {
            Ok(credentials) => {
                core.credentials = credentials;
                core.reusable = true;
            }
            Err(_) => warn!("reconnected session has no reusable credentials"),
        }
        core.link = Arc::new(link);
        drop(core);
        self.links.send_modify(|count| *count += 1);
        true
    }

    async fn until_stopped(&self) {
        let _ = self.stopped.subscribe().wait_for(|stopped| *stopped).await;
    }

    /// Consumes a pending wake or retry request; true if one was pending.
    fn take_retry_request(&self) -> bool {
        let mut core = lock(&self.core);
        let requested = core.wake || core.retry_now;
        core.wake = false;
        core.retry_now = false;
        requested
    }

    async fn wait_for_dead_link(&self) -> Option<Arc<L>> {
        loop {
            {
                let mut core = lock(&self.core);
                if core.shut_down {
                    return None;
                }
                core.retry_now = false;
                let woke = std::mem::take(&mut core.wake);
                if woke || core.link.is_invalid() {
                    if woke {
                        info!("forcing reconnect");
                    } else {
                        warn!("session lost, reconnecting");
                    }
                    return Some(Arc::clone(&core.link));
                }
            }
            tokio::select! {
                () = self.nudge.notified() => {}
                () = tokio::time::sleep(POLL_INTERVAL) => {}
            }
        }
    }

    /// Sleeps `delay` unless a wake or network nudge cuts it short.
    async fn wait_backoff(&self, delay: Duration, backoff: &mut Backoff) {
        let deadline = tokio::time::Instant::now() + delay;
        loop {
            tokio::select! {
                () = self.nudge.notified() => {}
                () = tokio::time::sleep_until(deadline) => return,
            }
            if self.is_shut_down() {
                return;
            }
            if self.take_retry_request() {
                backoff.reset();
                return;
            }
        }
    }

    async fn run<C: Connector<L>>(self: Arc<Self>, connector: C) {
        let mut backoff = Backoff::default();
        while let Some(dead) = self.wait_for_dead_link().await {
            dead.shutdown();
            backoff.reset();
            if !self.reconnect(&connector, &mut backoff).await {
                return;
            }
        }
    }

    /// Returns false when the supervisor must stop.
    async fn reconnect<C: Connector<L>>(&self, connector: &C, backoff: &mut Backoff) -> bool {
        let mut attempt = 1;
        let mut retry_in = Duration::ZERO;
        loop {
            self.emit(ConnectionState::Reconnecting {
                attempt,
                retry_in_secs: secs(retry_in),
            });
            if !retry_in.is_zero() {
                self.wait_backoff(retry_in, backoff).await;
                if self.is_shut_down() {
                    return false;
                }
                self.emit(ConnectionState::Reconnecting {
                    attempt,
                    retry_in_secs: 0,
                });
            }
            let credentials = lock(&self.core).credentials.clone();
            let result = tokio::select! {
                result = connector.connect(credentials) => result,
                () = self.until_stopped() => return false,
            };
            match result {
                Ok(link) => {
                    if !self.install(link) {
                        return false;
                    }
                    backoff.reset();
                    self.emit(ConnectionState::Connected);
                    return true;
                }
                Err(SessionError::CredentialsRejected | SessionError::InvalidStoredCredentials) => {
                    self.emit(ConnectionState::CredentialsRejected);
                    return false;
                }
                Err(error) => {
                    if self.is_shut_down() {
                        return false;
                    }
                    warn!("reconnect attempt {attempt} failed: {error}");
                    attempt = attempt.saturating_add(1);
                    retry_in = backoff.next_delay();
                }
            }
        }
    }
}

fn secs(duration: Duration) -> u32 {
    u32::try_from(duration.as_secs()).unwrap_or(u32::MAX)
}

/// Handle owned by `SpotSession`; dropping it shuts the supervisor down.
pub(crate) struct Supervisor<L: Link> {
    shared: Arc<Shared<L>>,
}

impl<L: Link> Supervisor<L> {
    /// Must be called inside a tokio runtime.
    /// `initial` are the credentials `link` connected with, the reconnect
    /// fallback while no session has yielded reusable ones.
    pub(crate) fn start<C: Connector<L>>(
        link: L,
        initial: StoredCredentials,
        connector: C,
    ) -> Self {
        let reusable = link.stored_credentials().ok();
        if reusable.is_none() {
            warn!(
                "session has no reusable credentials; reconnect falls back to the initial ones and wake is ignored"
            );
        }
        let shared = Arc::new(Shared {
            core: Mutex::new(Core {
                link: Arc::new(link),
                reusable: reusable.is_some(),
                credentials: reusable.unwrap_or(initial),
                shut_down: false,
                wake: false,
                retry_now: false,
            }),
            reporter: Mutex::new(Reporter {
                state: ConnectionState::Connected,
                observer: None,
                closed: false,
            }),
            nudge: Notify::new(),
            stopped: watch::Sender::new(false),
            links: watch::Sender::new(0),
        });
        tokio::spawn(Arc::clone(&shared).run(connector));
        Self { shared }
    }

    pub(crate) fn current_link(&self) -> Arc<L> {
        self.shared.current_link()
    }

    /// Changes once per link a reconnect installs, after `current_link`
    /// returns it; closes once the supervisor is gone.
    pub(crate) fn link_changes(&self) -> watch::Receiver<u64> {
        self.shared.links.subscribe()
    }

    pub(crate) fn set_observer(&self, observer: Arc<dyn ConnectionObserver>) {
        let state = {
            let mut reporter = lock(&self.shared.reporter);
            if reporter.closed {
                return;
            }
            reporter.observer = Some(Arc::clone(&observer));
            reporter.state.clone()
        };
        observer.on_state_changed(state);
    }

    /// Ignored while only the initial credentials exist: a healthy session
    /// must not be torn down to retry with a possibly expired token.
    pub(crate) fn reconnect_now(&self) {
        let mut core = lock(&self.shared.core);
        if core.shut_down {
            return;
        }
        if !core.reusable {
            info!("reconnect requested; no reusable credentials, keeping session");
            return;
        }
        core.wake = true;
        drop(core);
        self.shared.nudge.notify_one();
    }

    /// `available == false` is ignored: the poll notices a dead session.
    pub(crate) fn network_changed(&self, available: bool) {
        let reconnecting = matches!(
            lock(&self.shared.reporter).state,
            ConnectionState::Reconnecting { .. }
        );
        if !available || !reconnecting {
            return;
        }
        let mut core = lock(&self.shared.core);
        if core.shut_down {
            return;
        }
        core.retry_now = true;
        drop(core);
        self.shared.nudge.notify_one();
    }

    pub(crate) fn shutdown(&self) {
        let link = {
            let mut core = lock(&self.shared.core);
            if core.shut_down {
                return;
            }
            core.shut_down = true;
            Arc::clone(&core.link)
        };
        {
            let mut reporter = lock(&self.shared.reporter);
            reporter.closed = true;
            reporter.observer = None;
        }
        link.shutdown();
        self.shared.stopped.send_replace(true);
        self.shared.nudge.notify_one();
        info!("session shut down");
    }
}

impl<L: Link> Drop for Supervisor<L> {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::reusable_credentials;
    use librespot_core::authentication::Credentials;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use tokio::sync::oneshot;
    use tokio::time::Instant;

    const DEVICE_ID: &str = "dev-1234";

    struct FakeLink {
        id: u32,
        invalid: AtomicBool,
        shutdowns: AtomicU32,
        reusable: bool,
    }

    impl FakeLink {
        fn new(id: u32) -> Self {
            Self {
                id,
                invalid: AtomicBool::new(false),
                shutdowns: AtomicU32::new(0),
                reusable: true,
            }
        }

        fn without_credentials(id: u32) -> Self {
            Self {
                reusable: false,
                ..Self::new(id)
            }
        }

        fn kill(&self) {
            self.invalid.store(true, Ordering::SeqCst);
        }

        fn is_shut(&self) -> bool {
            self.shutdowns.load(Ordering::SeqCst) > 0
        }
    }

    fn initial_credentials() -> StoredCredentials {
        StoredCredentials::new(
            DEVICE_ID.to_owned(),
            Credentials::with_access_token("initial-token"),
        )
    }

    fn credentials_of(id: u32) -> StoredCredentials {
        StoredCredentials::new(
            DEVICE_ID.to_owned(),
            reusable_credentials(format!("user-{id}"), format!("auth-{id}").into_bytes()),
        )
    }

    impl Link for Arc<FakeLink> {
        fn is_invalid(&self) -> bool {
            self.invalid.load(Ordering::SeqCst) || self.is_shut()
        }

        fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
        }

        fn stored_credentials(&self) -> Result<StoredCredentials, SessionError> {
            if self.reusable {
                Ok(credentials_of(self.id))
            } else {
                Err(SessionError::Internal {
                    message: "no reusable credentials".to_owned(),
                })
            }
        }
    }

    enum Step {
        Succeed,
        Fail(SessionError),
        SucceedAfter(oneshot::Receiver<()>),
    }

    #[derive(Default)]
    struct Script {
        steps: Mutex<VecDeque<Step>>,
        calls: Mutex<Vec<(Instant, StoredCredentials)>>,
        links: Mutex<Vec<Arc<FakeLink>>>,
        next_id: AtomicU32,
    }

    impl Script {
        fn push(&self, step: Step) {
            lock(&self.steps).push_back(step);
        }

        fn calls(&self) -> Vec<(Instant, StoredCredentials)> {
            lock(&self.calls).clone()
        }

        fn link(&self, index: usize) -> Arc<FakeLink> {
            Arc::clone(&lock(&self.links)[index])
        }

        fn call_gaps_secs(&self) -> Vec<u64> {
            let calls = self.calls();
            calls
                .windows(2)
                .map(|w| (w[1].0 - w[0].0).as_secs())
                .collect()
        }
    }

    struct FakeConnector(Arc<Script>);

    impl Connector<Arc<FakeLink>> for FakeConnector {
        async fn connect(
            &self,
            credentials: StoredCredentials,
        ) -> Result<Arc<FakeLink>, SessionError> {
            let script = &self.0;
            lock(&script.calls).push((Instant::now(), credentials));
            let step = lock(&script.steps).pop_front();
            match step {
                Some(Step::Succeed) => {}
                Some(Step::SucceedAfter(gate)) => {
                    let _ = gate.await;
                }
                Some(Step::Fail(error)) => return Err(error),
                None => return Err(network()),
            }
            let id = 100 + script.next_id.fetch_add(1, Ordering::SeqCst);
            let link = Arc::new(FakeLink::new(id));
            lock(&script.links).push(Arc::clone(&link));
            Ok(link)
        }
    }

    fn network() -> SessionError {
        SessionError::Network {
            message: "unreachable".to_owned(),
        }
    }

    #[derive(Default)]
    struct Recorder(Mutex<Vec<ConnectionState>>);

    impl ConnectionObserver for Recorder {
        fn on_state_changed(&self, state: ConnectionState) {
            lock(&self.0).push(state);
        }
    }

    impl Recorder {
        fn states(&self) -> Vec<ConnectionState> {
            lock(&self.0).clone()
        }
    }

    struct Harness {
        supervisor: Supervisor<Arc<FakeLink>>,
        first: Arc<FakeLink>,
        script: Arc<Script>,
        recorder: Arc<Recorder>,
    }

    fn start() -> Harness {
        start_with(FakeLink::new(1))
    }

    fn start_with(first: FakeLink) -> Harness {
        let first = Arc::new(first);
        let script = Arc::new(Script::default());
        let supervisor = Supervisor::start(
            Arc::clone(&first),
            initial_credentials(),
            FakeConnector(Arc::clone(&script)),
        );
        let recorder = Arc::new(Recorder::default());
        supervisor.set_observer(recorder.clone());
        Harness {
            supervisor,
            first,
            script,
            recorder,
        }
    }

    async fn settle(seconds: u64) {
        tokio::time::sleep(Duration::from_secs(seconds)).await;
    }

    async fn wait_until(mut done: impl FnMut() -> bool) {
        for _ in 0..100_000 {
            if done() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("condition not reached");
    }

    fn reconnecting(attempt: u32, retry_in_secs: u32) -> ConnectionState {
        ConnectionState::Reconnecting {
            attempt,
            retry_in_secs,
        }
    }

    fn connected_count(recorder: &Recorder) -> usize {
        recorder
            .states()
            .iter()
            .filter(|s| **s == ConnectionState::Connected)
            .count()
    }

    #[test]
    fn backoff_sequence_doubles_then_caps_at_60() {
        let mut backoff = Backoff::default();
        let delays: Vec<u64> = (0..10).map(|_| backoff.next_delay().as_secs()).collect();
        assert_eq!(delays, [1, 2, 4, 8, 16, 32, 60, 60, 60, 60]);
    }

    #[test]
    fn backoff_stays_capped_after_many_failures() {
        let mut backoff = Backoff::default();
        for _ in 0..100 {
            backoff.next_delay();
        }
        assert_eq!(backoff.next_delay(), Duration::from_secs(60));
    }

    #[test]
    fn backoff_reset_restarts_sequence() {
        let mut backoff = Backoff::default();
        for _ in 0..5 {
            backoff.next_delay();
        }
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_secs(1));
        assert_eq!(backoff.next_delay(), Duration::from_secs(2));
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_after_dead_session_swaps_link_and_reports_connected() {
        let h = start();
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| connected_count(&h.recorder) == 2).await;

        assert_eq!(
            h.recorder.states(),
            [
                ConnectionState::Connected,
                reconnecting(1, 0),
                ConnectionState::Connected
            ]
        );
        assert!(Arc::ptr_eq(
            &*h.supervisor.current_link(),
            &h.script.link(0)
        ));
        assert!(h.first.is_shut());
    }

    async fn announced(links: &mut watch::Receiver<u64>) {
        tokio::time::timeout(Duration::from_secs(60), links.changed())
            .await
            .expect("no new link announced")
            .unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_announces_each_new_link_after_installing_it() {
        let h = start();
        let mut links = h.supervisor.link_changes();
        assert!(
            !links.has_changed().unwrap(),
            "the first link is no reconnect"
        );

        h.script.push(Step::Fail(network()));
        h.script.push(Step::Succeed);
        h.first.kill();
        announced(&mut links).await;
        assert!(Arc::ptr_eq(
            &*h.supervisor.current_link(),
            &h.script.link(0)
        ));
        assert_eq!(*links.borrow_and_update(), 1, "a failed attempt is no link");

        h.script.push(Step::Succeed);
        h.script.link(0).kill();
        announced(&mut links).await;
        assert!(Arc::ptr_eq(
            &*h.supervisor.current_link(),
            &h.script.link(1)
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn link_changes_close_once_the_supervisor_is_gone() {
        let h = start();
        let mut links = h.supervisor.link_changes();

        drop(h);

        assert!(links.changed().await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_failures_follow_backoff_delays() {
        let h = start();
        h.first.kill();
        wait_until(|| h.script.calls().len() == 9).await;

        assert_eq!(h.script.call_gaps_secs(), [1, 2, 4, 8, 16, 32, 60, 60]);
        let states = h.recorder.states();
        assert_eq!(
            &states[..6],
            [
                ConnectionState::Connected,
                reconnecting(1, 0),
                reconnecting(2, 1),
                reconnecting(2, 0),
                reconnecting(3, 2),
                reconnecting(3, 0),
            ]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_success_resets_backoff() {
        let h = start();
        h.script.push(Step::Fail(network()));
        h.script.push(Step::Fail(network()));
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| connected_count(&h.recorder) == 2).await;

        h.script.link(0).kill();
        wait_until(|| h.script.calls().len() == 5).await;
        assert_eq!(h.script.call_gaps_secs()[3], 1);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_on_wake_replaces_live_session() {
        let h = start();
        h.script.push(Step::Succeed);
        h.supervisor.reconnect_now();
        wait_until(|| connected_count(&h.recorder) == 2).await;

        assert!(h.first.is_shut());
        assert!(Arc::ptr_eq(
            &*h.supervisor.current_link(),
            &h.script.link(0)
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_on_wake_cuts_backoff_and_resets_it() {
        let h = start();
        h.first.kill();
        wait_until(|| h.script.calls().len() == 7).await;
        settle(1).await;
        h.supervisor.reconnect_now();
        wait_until(|| h.script.calls().len() == 8).await;
        wait_until(|| h.script.calls().len() == 9).await;

        let gaps = h.script.call_gaps_secs();
        assert_eq!(gaps[6], 1);
        assert_eq!(gaps[7], 1);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_on_network_available_cuts_60s_wait() {
        let h = start();
        h.first.kill();
        wait_until(|| h.script.calls().len() == 7).await;
        assert!(h.recorder.states().contains(&reconnecting(8, 60)));
        settle(5).await;
        h.script.push(Step::Succeed);
        h.supervisor.network_changed(true);
        wait_until(|| connected_count(&h.recorder) == 2).await;

        assert_eq!(h.script.call_gaps_secs()[6], 5);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_ignores_network_changes_while_connected() {
        let h = start();
        h.supervisor.network_changed(true);
        h.supervisor.network_changed(false);
        settle(10).await;

        assert!(h.script.calls().is_empty());
        assert_eq!(h.recorder.states(), [ConnectionState::Connected]);
        assert!(!h.first.is_shut());
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_stops_when_credentials_rejected() {
        for error in [
            SessionError::CredentialsRejected,
            SessionError::InvalidStoredCredentials,
        ] {
            let h = start();
            h.script.push(Step::Fail(error));
            h.first.kill();
            wait_until(|| h.recorder.states().len() == 3).await;
            settle(600).await;
            h.supervisor.reconnect_now();
            h.supervisor.network_changed(true);
            settle(600).await;

            assert_eq!(
                h.recorder.states(),
                [
                    ConnectionState::Connected,
                    reconnecting(1, 0),
                    ConnectionState::CredentialsRejected
                ]
            );
            assert_eq!(h.script.calls().len(), 1);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_shutdown_is_idempotent_and_silences_observer() {
        let h = start();
        h.supervisor.shutdown();
        h.supervisor.shutdown();
        h.supervisor.reconnect_now();
        h.supervisor.network_changed(true);
        h.first.kill();
        settle(600).await;

        assert_eq!(h.first.shutdowns.load(Ordering::SeqCst), 1);
        assert!(h.script.calls().is_empty());
        assert_eq!(h.recorder.states(), [ConnectionState::Connected]);

        let late = Arc::new(Recorder::default());
        h.supervisor.set_observer(late.clone());
        assert!(late.states().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_in_flight_connect_is_cancelled_by_shutdown() {
        let h = start();
        let (release, gate) = oneshot::channel();
        h.script.push(Step::SucceedAfter(gate));
        h.first.kill();
        wait_until(|| h.script.calls().len() == 1).await;
        h.supervisor.shutdown();
        wait_until(|| release.is_closed()).await;
        settle(600).await;

        assert!(lock(&h.script.links).is_empty());
        assert!(Arc::ptr_eq(&*h.supervisor.current_link(), &h.first));
        assert_eq!(
            h.recorder.states(),
            [ConnectionState::Connected, reconnecting(1, 0)]
        );
        assert_eq!(h.script.calls().len(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_wake_during_in_flight_attempt_is_safe() {
        let h = start();
        let (release, gate) = oneshot::channel();
        h.script.push(Step::SucceedAfter(gate));
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| h.script.calls().len() == 1).await;
        h.supervisor.reconnect_now();
        h.supervisor.reconnect_now();
        release.send(()).unwrap();
        wait_until(|| connected_count(&h.recorder) == 3).await;
        settle(60).await;

        assert_eq!(h.script.calls().len(), 2);
        assert!(h.script.link(0).is_shut());
        assert!(Arc::ptr_eq(
            &*h.supervisor.current_link(),
            &h.script.link(1)
        ));
    }

    /// Records whether any call came while the reporter lock was held.
    struct Reentrant {
        shared: Arc<Shared<Arc<FakeLink>>>,
        calls: AtomicU32,
        locked: AtomicBool,
    }

    impl ConnectionObserver for Reentrant {
        fn on_state_changed(&self, _: ConnectionState) {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.shared.reporter.try_lock().is_err() {
                self.locked.store(true, Ordering::SeqCst);
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_observer_is_called_without_the_reporter_lock() {
        let h = start();
        let observer = Arc::new(Reentrant {
            shared: Arc::clone(&h.supervisor.shared),
            calls: AtomicU32::new(0),
            locked: AtomicBool::new(false),
        });
        h.supervisor.set_observer(observer.clone());
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| observer.calls.load(Ordering::SeqCst) >= 3).await;
        assert!(
            !observer.locked.load(Ordering::SeqCst),
            "told under the lock"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_set_observer_delivers_current_state_immediately() {
        let h = start();
        assert_eq!(h.recorder.states(), [ConnectionState::Connected]);

        h.first.kill();
        wait_until(|| h.script.calls().len() == 2).await;
        let replacement = Arc::new(Recorder::default());
        h.supervisor.set_observer(replacement.clone());

        let current = lock(&h.supervisor.shared.reporter).state.clone();
        assert_eq!(replacement.states(), [current]);
        let before = h.recorder.states().len();
        settle(10).await;
        assert_eq!(h.recorder.states().len(), before);
        assert!(replacement.states().len() > 1);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_reuses_device_id_and_latest_credentials() {
        let h = start();
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| connected_count(&h.recorder) == 2).await;
        h.script.push(Step::Succeed);
        h.script.link(0).kill();
        wait_until(|| connected_count(&h.recorder) == 3).await;

        let calls = h.script.calls();
        assert_eq!(calls[0].1, credentials_of(1));
        assert_eq!(calls[1].1, credentials_of(100));
        assert!(calls.iter().all(|(_, c)| c.device_id == DEVICE_ID));
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_without_credentials_ignores_wake() {
        let h = start_with(FakeLink::without_credentials(1));
        h.supervisor.reconnect_now();
        settle(600).await;

        assert!(h.script.calls().is_empty());
        assert!(!h.first.is_shut());
        assert_eq!(h.recorder.states(), [ConnectionState::Connected]);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_without_credentials_falls_back_to_initial_ones() {
        let h = start_with(FakeLink::without_credentials(1));
        h.script.push(Step::Fail(network()));
        h.script.push(Step::Succeed);
        h.first.kill();
        wait_until(|| connected_count(&h.recorder) == 2).await;
        h.script.push(Step::Succeed);
        h.supervisor.reconnect_now();
        wait_until(|| connected_count(&h.recorder) == 3).await;

        let calls = h.script.calls();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[0].1, initial_credentials());
        assert_eq!(calls[1].1, initial_credentials());
        assert_eq!(calls[2].1, credentials_of(100));
        assert!(
            !h.recorder
                .states()
                .contains(&ConnectionState::CredentialsRejected)
        );
    }
}
