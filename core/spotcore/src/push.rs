//! Waits for dealer pushes under one URI prefix, resubscribing whenever a
//! reconnect replaces the session.

use std::time::Duration;

use futures_util::StreamExt;
use librespot_core::Session;
use librespot_core::dealer::Subscription;
use librespot_core::dealer::protocol::Message;

use crate::session::SpotSession;

/// How often a quiet wait checks whether a reconnect replaced the session.
const SESSION_CHECK: Duration = Duration::from_secs(30);
const RESUBSCRIBE_DELAY: Duration = Duration::from_secs(5);

pub(crate) struct PushWatch {
    prefix: &'static str,
    push: tokio::sync::Mutex<Option<Push>>,
}

struct Push {
    session_id: String,
    subscription: Subscription,
}

impl PushWatch {
    pub(crate) fn new(prefix: &'static str) -> Self {
        Self {
            prefix,
            push: tokio::sync::Mutex::new(None),
        }
    }

    /// The next push under the prefix, or `None` when a reconnect replaced
    /// the session (a push may have been missed, so resync everything).
    pub(crate) async fn next(&self, spot: &SpotSession) -> Option<Message> {
        let mut push = self.push.lock().await;
        loop {
            let session = spot.current_session();
            let session_id = session.session_id();
            if push.as_ref().is_none_or(|p| p.session_id != session_id) {
                match self.subscribe(&session).await {
                    Ok(subscription) => {
                        *push = Some(Push {
                            session_id,
                            subscription,
                        })
                    }
                    Err(e) => {
                        log::warn!("push subscription to {} failed: {e}", self.prefix);
                        drop(session);
                        tokio::time::sleep(RESUBSCRIBE_DELAY).await;
                        continue;
                    }
                }
            }
            drop(session);

            let current = push.as_mut().expect("subscribed above");
            tokio::select! {
                message = current.subscription.next() => match message {
                    Some(message) => return Some(message),
                    None => {
                        *push = None;
                        tokio::time::sleep(RESUBSCRIBE_DELAY).await;
                    }
                },
                _ = tokio::time::sleep(SESSION_CHECK) => {
                    if spot.current_session().session_id() != current.session_id {
                        *push = None;
                        return None;
                    }
                }
            }
        }
    }

    async fn subscribe(&self, session: &Session) -> Result<Subscription, librespot_core::Error> {
        let subscription = session.dealer().add_listen_for(self.prefix)?;
        // Fails harmlessly when another component already launched the dealer.
        if let Err(e) = session.dealer().start().await {
            log::debug!("dealer already started: {e}");
        }
        Ok(subscription)
    }
}
