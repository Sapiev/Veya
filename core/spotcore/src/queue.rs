//! Play order with Spotify's semantics: a context (album, playlist, radio)
//! plus a user "Up Next" list that plays before the rest of the context.

use std::collections::VecDeque;

use librespot_core::SpotifyUri;
use rand::SeedableRng;
use rand::rngs::SmallRng;
use rand::seq::SliceRandom;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum RepeatMode {
    #[default]
    Off,
    Context,
    Track,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Queue {
    /// Context in its original order.
    tracks: Vec<SpotifyUri>,
    /// Play order as indices into `tracks`; a permutation while shuffled.
    order: Vec<usize>,
    /// Index into `order` of the current or last-played context track.
    pos: usize,
    up_next: VecDeque<SpotifyUri>,
    /// A track taken from Up Next that is playing now; the context resumes
    /// after `pos` once it ends.
    queued: Option<SpotifyUri>,
    shuffle: bool,
    pub repeat: RepeatMode,
}

impl Queue {
    /// Replaces the context and starts at its first track; Up Next survives,
    /// as in Spotify.
    pub fn set_context(&mut self, tracks: Vec<SpotifyUri>, seed: u64) {
        self.order = (0..tracks.len()).collect();
        self.tracks = tracks;
        self.pos = 0;
        self.queued = None;
        if self.shuffle {
            self.order.shuffle(&mut SmallRng::seed_from_u64(seed));
        }
    }

    /// Like `set_context`, but `tracks[start]` plays first even when shuffled.
    pub fn set_context_at(&mut self, tracks: Vec<SpotifyUri>, start: usize, seed: u64) {
        self.set_context(tracks, seed);
        if let Some(at) = self.order.iter().position(|&i| i == start) {
            if self.shuffle {
                self.order.swap(0, at);
            } else {
                self.pos = at;
            }
        }
    }

    pub fn tracks(&self) -> &[SpotifyUri] {
        &self.tracks
    }

    pub fn shuffle(&self) -> bool {
        self.shuffle
    }

    /// Reorders what comes after the current track; the current one keeps
    /// playing either way.
    pub fn set_shuffle(&mut self, on: bool, seed: u64) {
        if on == self.shuffle {
            return;
        }
        self.shuffle = on;
        let Some(&current) = self.order.get(self.pos) else {
            return;
        };
        self.order = (0..self.tracks.len()).collect();
        if on {
            self.order.shuffle(&mut SmallRng::seed_from_u64(seed));
            let at = self.order.iter().position(|&i| i == current).unwrap_or(0);
            self.order.swap(0, at);
            self.pos = 0;
        } else {
            self.pos = current;
        }
    }

    pub fn current(&self) -> Option<&SpotifyUri> {
        self.queued
            .as_ref()
            .or_else(|| self.tracks.get(*self.order.get(self.pos)?))
    }

    /// Next track to play, or `None` when the context has run out. Repeat
    /// track only holds for a track ending on its own, not for a skip.
    pub fn advance(&mut self, skipped: bool) -> Option<&SpotifyUri> {
        if !skipped && self.repeat == RepeatMode::Track {
            return self.current();
        }
        if let Some(track) = self.up_next.pop_front() {
            self.queued = Some(track);
            return self.current();
        }
        self.queued = None;
        if self.pos + 1 < self.order.len() {
            self.pos += 1;
        } else if self.repeat != RepeatMode::Off && !self.order.is_empty() {
            self.pos = 0;
        } else {
            return None;
        }
        self.current()
    }

    /// What `advance(false)` would return, without moving the queue. Used to
    /// preload the next track for gapless playback.
    pub fn upcoming(&self) -> Option<&SpotifyUri> {
        if self.repeat == RepeatMode::Track {
            return self.current();
        }
        if let Some(track) = self.up_next.front() {
            return Some(track);
        }
        let next = if self.pos + 1 < self.order.len() {
            self.pos + 1
        } else if self.repeat != RepeatMode::Off {
            0
        } else {
            return None;
        };
        self.tracks.get(*self.order.get(next)?)
    }

    /// Steps back one context track. From an Up Next track it returns to the
    /// context track played before it; on the first track it wraps under
    /// repeat and otherwise stays there.
    pub fn back(&mut self) -> Option<&SpotifyUri> {
        if self.queued.take().is_none() {
            if self.pos > 0 {
                self.pos -= 1;
            } else if self.repeat != RepeatMode::Off && !self.order.is_empty() {
                self.pos = self.order.len() - 1;
            }
        }
        self.current()
    }

    pub fn play_next(&mut self, track: SpotifyUri) {
        self.up_next.push_front(track);
    }

    pub fn add(&mut self, track: SpotifyUri) {
        self.up_next.push_back(track);
    }

    pub fn remove(&mut self, index: usize) -> Option<SpotifyUri> {
        self.up_next.remove(index)
    }

    /// Moves the Up Next entry at `from` so it ends up at `to`.
    pub fn reorder(&mut self, from: usize, to: usize) -> bool {
        if to >= self.up_next.len() {
            return false;
        }
        let Some(track) = self.up_next.remove(from) else {
            return false;
        };
        self.up_next.insert(to, track);
        true
    }

    pub fn clear_up_next(&mut self) {
        self.up_next.clear();
    }

    pub fn up_next(&self) -> impl Iterator<Item = &SpotifyUri> {
        self.up_next.iter()
    }

    /// Context tracks still to come, in play order.
    pub fn next_from_context(&self) -> impl Iterator<Item = &SpotifyUri> {
        self.order
            .iter()
            .skip(self.pos + 1)
            .map(|&i| &self.tracks[i])
    }

    /// Context tracks played so far, oldest first.
    pub fn played(&self) -> impl Iterator<Item = &SpotifyUri> {
        self.order
            .iter()
            .take(self.pos + 1)
            .map(|&i| &self.tracks[i])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(n: u8) -> SpotifyUri {
        SpotifyUri::from_uri(&format!("spotify:track:4uLU6hMCjMI75M1A2tKUQ{n}")).unwrap()
    }

    fn context(len: u8) -> Queue {
        let mut q = Queue::default();
        q.set_context((0..len).map(track).collect(), 7);
        q
    }

    fn played_by_advancing(q: &mut Queue, n: usize) -> Vec<SpotifyUri> {
        (0..n).filter_map(|_| q.advance(false).cloned()).collect()
    }

    #[test]
    fn advance_walks_forward_and_stops_at_end() {
        let mut q = context(2);
        assert_eq!(q.current(), Some(&track(0)));
        assert_eq!(q.advance(false), Some(&track(1)));
        assert_eq!(q.advance(false), None);
    }

    #[test]
    fn upcoming_matches_advance_without_moving() {
        for repeat in [RepeatMode::Off, RepeatMode::Context, RepeatMode::Track] {
            for shuffle in [false, true] {
                let mut q = context(4);
                q.repeat = repeat;
                q.set_shuffle(shuffle, 3);
                q.add(track(9));
                for _ in 0..7 {
                    let peeked = q.upcoming().cloned();
                    assert_eq!(q.upcoming().cloned(), peeked);
                    assert_eq!(
                        q.advance(false).cloned(),
                        peeked,
                        "{repeat:?} shuffle={shuffle}"
                    );
                }
            }
        }
    }

    #[test]
    fn back_steps_back_and_restarts_first_track() {
        let mut q = context(2);
        q.advance(false);
        assert_eq!(q.back(), Some(&track(0)));
        assert_eq!(q.back(), Some(&track(0)));
    }

    #[test]
    fn empty_queue_has_nothing_to_play() {
        let mut q = Queue {
            repeat: RepeatMode::Context,
            ..Queue::default()
        };
        assert_eq!(q.current(), None);
        assert_eq!(q.advance(true), None);
        assert_eq!(q.back(), None);
    }

    #[test]
    fn up_next_plays_before_the_context_then_resumes_it() {
        let mut q = context(3);
        q.add(track(8));
        q.play_next(track(9));
        assert_eq!(
            played_by_advancing(&mut q, 4),
            [track(9), track(8), track(1), track(2)]
        );
    }

    #[test]
    fn back_from_up_next_returns_to_the_context_track_before_it() {
        let mut q = context(3);
        q.advance(false);
        q.add(track(9));
        q.advance(false);
        assert_eq!(q.back(), Some(&track(1)));
        assert_eq!(q.advance(false), Some(&track(2)));
    }

    #[test]
    fn up_next_survives_a_new_context() {
        let mut q = context(2);
        q.add(track(9));
        q.set_context(vec![track(5)], 1);
        assert_eq!(q.advance(false), Some(&track(9)));
    }

    #[test]
    fn remove_reorder_and_clear_edit_up_next() {
        let mut q = context(1);
        for n in [5, 6, 7] {
            q.add(track(n));
        }
        assert!(q.reorder(2, 0));
        assert_eq!(q.remove(1), Some(track(5)));
        assert_eq!(
            q.up_next().cloned().collect::<Vec<_>>(),
            [track(7), track(6)]
        );
        assert!(!q.reorder(0, 2));
        assert!(!q.reorder(5, 0));
        assert_eq!(q.remove(9), None);
        q.clear_up_next();
        assert_eq!(q.up_next().count(), 0);
    }

    #[test]
    fn repeat_context_wraps_both_ways() {
        let mut q = context(2);
        q.repeat = RepeatMode::Context;
        assert_eq!(q.back(), Some(&track(1)));
        assert_eq!(q.advance(false), Some(&track(0)));
    }

    #[test]
    fn repeat_track_replays_on_end_but_skip_moves_on() {
        let mut q = context(2);
        q.add(track(9));
        q.repeat = RepeatMode::Track;
        assert_eq!(q.advance(false), Some(&track(0)));
        assert_eq!(q.advance(true), Some(&track(9)));
        assert_eq!(q.advance(false), Some(&track(9)));
        assert_eq!(q.advance(true), Some(&track(1)));
        assert_eq!(q.advance(true), Some(&track(0)), "skip wraps under repeat");
    }

    #[test]
    fn shuffle_keeps_the_current_track_and_plays_every_track_once() {
        let mut q = context(10);
        q.advance(false);
        q.advance(false);
        q.set_shuffle(true, 42);
        assert_eq!(q.current(), Some(&track(2)));
        let mut rest = q.next_from_context().cloned().collect::<Vec<_>>();
        assert_eq!(rest.len(), 9);
        rest.push(track(2));
        rest.sort_by_key(|t| t.to_uri().unwrap());
        assert_eq!(rest, (0..10).map(track).collect::<Vec<_>>());
    }

    #[test]
    fn unshuffle_resumes_original_order_after_the_current_track() {
        let mut q = context(10);
        q.set_shuffle(true, 42);
        q.advance(false);
        let current = q.current().cloned().unwrap();
        q.set_shuffle(false, 0);
        assert_eq!(q.current(), Some(&current));
        let at = q.tracks().iter().position(|t| *t == current).unwrap();
        assert_eq!(q.next_from_context().next(), q.tracks().get(at + 1));
    }

    #[test]
    fn shuffle_with_repeat_context_loops_the_shuffled_order() {
        let mut q = context(4);
        q.repeat = RepeatMode::Context;
        q.set_shuffle(true, 3);
        let first_pass = played_by_advancing(&mut q, 4);
        let second_pass = played_by_advancing(&mut q, 4);
        assert_eq!(first_pass, second_pass);
    }

    #[test]
    fn set_context_at_starts_at_the_chosen_track() {
        let mut q = Queue::default();
        q.set_context_at((0..5).map(track).collect(), 3, 7);
        assert_eq!(q.current(), Some(&track(3)));
        assert_eq!(
            q.played().cloned().collect::<Vec<_>>(),
            (0..=3).map(track).collect::<Vec<_>>()
        );
        assert_eq!(q.advance(false), Some(&track(4)));
    }

    #[test]
    fn set_context_at_while_shuffled_plays_the_chosen_track_first_then_the_rest_once() {
        let mut q = Queue::default();
        q.set_shuffle(true, 0);
        q.set_context_at((0..10).map(track).collect(), 6, 42);
        assert_eq!(q.current(), Some(&track(6)));
        let mut rest = played_by_advancing(&mut q, 9);
        rest.sort_by_key(|t| format!("{t:?}"));
        let mut expected: Vec<_> = (0..10).filter(|&n| n != 6).map(track).collect();
        expected.sort_by_key(|t| format!("{t:?}"));
        assert_eq!(rest, expected);
    }

    #[test]
    fn set_context_at_out_of_range_starts_at_the_first_track() {
        let mut q = Queue::default();
        q.set_context_at((0..3).map(track).collect(), 9, 7);
        assert_eq!(q.current(), Some(&track(0)));
    }

    #[test]
    fn loading_while_shuffled_shuffles_the_new_context() {
        let mut q = Queue::default();
        q.set_shuffle(true, 0);
        q.set_context((0..10).map(track).collect(), 42);
        assert_ne!(
            q.played()
                .chain(q.next_from_context())
                .cloned()
                .collect::<Vec<_>>(),
            q.tracks().to_vec()
        );
    }
}
