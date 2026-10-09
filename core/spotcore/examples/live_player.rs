//! Manual latency check for PBI-202 against a real Premium account.
//!
//! `cargo run -p spotcore --example live_player -- spotify:album:<id>`
//!
//! Signs in through the browser each run and stores nothing. Audio is
//! drained at real-time pace and discarded, so the run is silent.

use std::ffi::c_void;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use spotcore::{
    AudioOutput, Bitrate, LoginFlow, PlaybackEvent, PlayerObserver, SpotPlayer, SpotSession,
    default_oauth_config,
};

unsafe extern "C" {
    fn spotcore_audio_render(
        handle: *mut c_void,
        left: *mut f32,
        right: *mut f32,
        frames: usize,
    ) -> usize;
}

const DRAIN_TICK: Duration = Duration::from_millis(10);
const FRAMES_PER_TICK: usize = 441;
const EVENT_TIMEOUT: Duration = Duration::from_secs(10);

struct Forward(std::sync::Mutex<Sender<PlaybackEvent>>);

impl PlayerObserver for Forward {
    fn on_event(&self, event: PlaybackEvent) {
        let _ = self.0.lock().unwrap().send(event);
    }
}

/// Prints every event and returns how long until one matched `done`.
fn time_until(
    events: &Receiver<PlaybackEvent>,
    label: &str,
    done: impl Fn(&PlaybackEvent) -> bool,
) {
    let start = Instant::now();
    loop {
        match events.recv_timeout(EVENT_TIMEOUT.saturating_sub(start.elapsed())) {
            Ok(event) => {
                println!("  {:>6} ms  {event:?}", start.elapsed().as_millis());
                if done(&event) {
                    println!("{label}: {} ms", start.elapsed().as_millis());
                    return;
                }
            }
            Err(_) => {
                println!("{label}: no matching event within {EVENT_TIMEOUT:?}");
                return;
            }
        }
    }
}

fn drain_forever(handle: u64) {
    std::thread::spawn(move || {
        let mut left = vec![0f32; FRAMES_PER_TICK];
        let mut right = vec![0f32; FRAMES_PER_TICK];
        loop {
            // SAFETY: the handle is never freed and only this thread renders.
            unsafe {
                spotcore_audio_render(
                    handle as *mut c_void,
                    left.as_mut_ptr(),
                    right.as_mut_ptr(),
                    FRAMES_PER_TICK,
                );
            }
            std::thread::sleep(DRAIN_TICK);
        }
    });
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let uri = std::env::args()
        .nth(1)
        .ok_or("usage: live_player <spotify:uri>")?;

    let login = LoginFlow::start(default_oauth_config()).await?;
    println!("Opening browser for sign-in...");
    std::process::Command::new("open")
        .arg(login.authorize_url())
        .status()?;
    let tokens = login.finish().await?;
    let session = SpotSession::connect_with_token(tokens.access_token, None).await?;
    println!("Signed in.");

    let output = AudioOutput::new();
    drain_forever(output.take_render_handle());
    let (tx, events) = channel();
    let player = SpotPlayer::new(
        session,
        output,
        Arc::new(Forward(tx.into())),
        u16::MAX,
        None,
        Bitrate::Kbps320,
    )
    .await?;

    let playing = |e: &PlaybackEvent| matches!(e, PlaybackEvent::Playing { .. });
    let start = Instant::now();
    player.load(uri, 0, true).await?;
    println!(
        "load resolved context in {} ms",
        start.elapsed().as_millis()
    );
    time_until(&events, "load -> playing (target < 1000)", playing);

    std::thread::sleep(Duration::from_secs(3));
    player.pause();
    time_until(&events, "pause -> paused (target < 100)", |e| {
        matches!(e, PlaybackEvent::Paused { .. })
    });

    std::thread::sleep(Duration::from_secs(1));
    player.play();
    time_until(&events, "play -> playing (target < 100)", playing);

    std::thread::sleep(Duration::from_secs(3));
    player.seek(30_000);
    time_until(
        &events,
        "seek -> position",
        |e| matches!(e, PlaybackEvent::Position { position_ms, .. } if *position_ms >= 30_000),
    );

    player.next();
    time_until(&events, "next -> playing (target < 1000)", playing);

    std::thread::sleep(Duration::from_secs(3));
    player.previous();
    time_until(&events, "previous -> playing (target < 1000)", playing);

    player.stop();
    time_until(&events, "stop -> stopped", |e| {
        matches!(e, PlaybackEvent::Stopped)
    });
    Ok(())
}
