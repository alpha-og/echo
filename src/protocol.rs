//! Shared wire protocol between the iOS publisher, the Rust relay, and Mac clients.
//!
//! Transport:
//! - `GET /status` -> latest [`NowPlayingState`] (or 204)
//! - `POST /command` -> broadcast [`Command`] to connected iPhones
//! - `GET /ws?role=iphone` -> iPhone: sends `State`, receives `Command`
//! - `GET /ws?role=mac` -> Mac live tail: receives `State`, may send `Command`

use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

/// Which device a state snapshot comes from, or a command targets.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum DeviceRole {
    Iphone,
    Mac,
    #[default]
    Unknown,
}

/// Playback state normalized from `MPMusicPlaybackState`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum PlaybackState {
    Playing,
    Paused,
    Stopped,
    #[default]
    Unknown,
}

/// Now-playing snapshot published by iOS.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct NowPlayingState {
    /// Apple Music catalog id (`MPMediaItemPropertyPlaybackStoreID`). Key to exact handoff.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    /// Track duration in seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    /// Playback position in seconds at `timestamp_ms`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed: Option<f64>,
    /// Playback rate at `timestamp_ms` (1.0 = playing, 0.0 = paused).
    #[serde(default)]
    pub rate: f32,
    /// Output volume 0.0..=1.0 when the publisher reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<f32>,
    #[serde(default)]
    pub state: PlaybackState,
    /// Unix millis when `elapsed` was sampled. Lets Mac extrapolate position.
    #[serde(default)]
    pub timestamp_ms: i64,
    /// Upcoming queue store IDs when known (for gapless handoff).
    #[serde(default)]
    pub queue_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    /// Base64 JPEG album art (~192px, sender includes it only on track change).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork: Option<String>,
    /// Which device published this. Set by the relay from the connection
    /// role; senders without a role default to iphone.
    #[serde(default)]
    pub origin: DeviceRole,
}

impl NowPlayingState {
    /// Max chars for free-text fields (DoS cap on WS/HTTP payloads).
    pub const MAX_TEXT: usize = 500;
    /// Max queued ids accepted per snapshot.
    pub const MAX_QUEUE: usize = 200;
    /// Max track length accepted (24h).
    pub const MAX_SECS: f64 = 86_400.0;

    /// Position extrapolated to now. Clamped to `[0, duration]`.
    pub fn effective_elapsed(&self, now_ms: i64) -> Option<f64> {
        let base = self.elapsed?;
        let dt = if self.rate > 0.0 && self.state == PlaybackState::Playing {
            (now_ms - self.timestamp_ms) as f64 / 1000.0 * self.rate as f64
        } else {
            0.0
        };
        let pos = (base + dt).max(0.0);
        match self.duration {
            Some(d) => Some(pos.min(d)),
            None => Some(pos),
        }
    }

    /// Fuzzy display identity (AVRCP-grade). Prefer `store_id` when present.
    #[allow(dead_code)]
    pub fn fuzzy_key(&self) -> String {
        format!(
            "{} — {} — {}",
            self.title.as_deref().unwrap_or(""),
            self.artist.as_deref().unwrap_or(""),
            self.album.as_deref().unwrap_or("")
        )
    }

    /// Reject malformed/oversize snapshots before they touch shared state.
    pub fn validate(&self) -> Result<(), String> {
        if let Some(id) = &self.store_id
            && !is_store_id(id)
        {
            return Err("store_id must be 1-20 ASCII digits".into());
        }
        for (name, v) in [
            ("title", &self.title),
            ("artist", &self.artist),
            ("album", &self.album),
            ("device_name", &self.device_name),
        ] {
            if let Some(t) = v {
                if t.len() > Self::MAX_TEXT {
                    return Err(format!("{name} too long"));
                }
                if t.contains(|c: char| c.is_control() && c != '\t') {
                    return Err(format!("{name} contains control chars"));
                }
            }
        }
        for x in [self.duration, self.elapsed].into_iter().flatten() {
            if !x.is_finite() || x < 0.0 || x > Self::MAX_SECS {
                return Err("duration/elapsed out of range".into());
            }
        }
        if !self.rate.is_finite() || self.rate < 0.0 || self.rate > 4.0 {
            return Err("rate out of range".into());
        }
        if let Some(v) = self.volume
            && (!v.is_finite() || !(0.0..=1.0).contains(&v))
        {
            return Err("volume out of range".into());
        }
        if self.queue_ids.len() > Self::MAX_QUEUE {
            return Err("queue_ids too long".into());
        }
        for q in &self.queue_ids {
            if !is_store_id(q) {
                return Err("queue_ids must be ASCII digits".into());
            }
        }
        if let Some(a) = &self.artwork {
            if a.len() > 100_000 {
                return Err("artwork too large".into());
            }
            if !a.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b)) {
                return Err("artwork must be base64".into());
            }
        }
        Ok(())
    }
}

/// Apple Music catalog ids are numeric strings.
pub fn is_store_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_digit())
}

/// Control command sent Mac <-> iPhone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Command {
    pub action: CommandAction,
    /// Target position for `seek`, or start position for `play_store_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<f64>,
    /// Catalog id for `play_store_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_id: Option<String>,
    /// Output volume 0.0..=1.0 for `volume`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volume: Option<f32>,
    /// Who should execute it. `Unknown` (legacy clients) means iphone.
    #[serde(default)]
    pub target: DeviceRole,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CommandAction {
    Play,
    Pause,
    Toggle,
    Next,
    Previous,
    Seek,
    PlayStoreId,
    Volume,
}

impl Command {
    fn base(action: CommandAction, position: Option<f64>, store_id: Option<String>) -> Self {
        Self { action, position, store_id, volume: None, target: DeviceRole::Unknown }
    }
    /// Route this command at a specific device.
    pub fn to(mut self, target: DeviceRole) -> Self {
        self.target = target;
        self
    }
    /// Should `role` execute this? `Unknown` targets mean legacy iphone behavior.
    pub fn addressed_to(&self, role: DeviceRole) -> bool {
        self.target == DeviceRole::Unknown || self.target == role
    }
    pub fn play() -> Self {
        Self::base(CommandAction::Play, None, None)
    }
    pub fn pause() -> Self {
        Self::base(CommandAction::Pause, None, None)
    }
    pub fn toggle() -> Self {
        Self::base(CommandAction::Toggle, None, None)
    }
    pub fn next() -> Self {
        Self::base(CommandAction::Next, None, None)
    }
    pub fn previous() -> Self {
        Self::base(CommandAction::Previous, None, None)
    }
    pub fn seek(position: f64) -> Self {
        Self::base(CommandAction::Seek, Some(position), None)
    }
    pub fn volume(level: f32) -> Self {
        Self { action: CommandAction::Volume, position: None, store_id: None, volume: Some(level), target: DeviceRole::Unknown }
    }
    pub fn play_store_id(store_id: impl Into<String>, position: f64) -> Self {
Self::base(CommandAction::PlayStoreId, Some(position), Some(store_id.into()))
    }

    /// Reject malformed commands before broadcast/execution.
    pub fn validate(&self) -> Result<(), String> {
        if let Some(p) = self.position
            && (!p.is_finite() || p < 0.0 || p > NowPlayingState::MAX_SECS)
        {
            return Err("position out of range".into());
        }
        if let Some(v) = self.volume
            && (!v.is_finite() || !(0.0..=1.0).contains(&v))
        {
            return Err("volume out of range".into());
        }
        if let Some(id) = &self.store_id
            && !is_store_id(id)
        {
            return Err("store_id must be 1-20 ASCII digits".into());
        }
        match self.action {
            CommandAction::Seek if self.position.is_none() => {
                return Err("seek requires position".into());
            }
            CommandAction::PlayStoreId if self.store_id.is_none() => {
                return Err("play_store_id requires store_id".into());
            }
            CommandAction::Volume if self.volume.is_none() => {
                return Err("volume requires volume".into());
            }
            _ => {}
        }
        Ok(())
    }
}

/// WebSocket envelope. `type` discriminates the payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WsMessage {
    Hello { role: String },
    State(NowPlayingState),
    Command(Command),
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Decide which side is "active" for smart display and default control target:
/// the side that is playing wins; both playing (or neither) defers to `me`.
/// Stale snapshots (older than `stale_ms`) never win over a fresh one.
///
/// Contract shared with both apps: each client ports this rule and layers
/// last-active stickiness on top, so a pause never flips the display to the
/// other side. The unit tests below pin the rule; keep all three in step.
#[allow(dead_code)]
pub fn active_side(
    iphone: Option<&NowPlayingState>,
    mac: Option<&NowPlayingState>,
    me: DeviceRole,
    now_ms: i64,
    stale_ms: i64,
) -> DeviceRole {
    let fresh = |s: &NowPlayingState| now_ms - s.timestamp_ms <= stale_ms;
    let playing = |s: Option<&NowPlayingState>| {
        s.filter(|x| x.state == PlaybackState::Playing)
            .filter(|x| fresh(x))
            .is_some()
    };
    match (playing(iphone), playing(mac)) {
        (true, false) => DeviceRole::Iphone,
        (false, true) => DeviceRole::Mac,
        _ => me,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_roundtrip() {
        let s = NowPlayingState {
            store_id: Some("123456789".into()),
            title: Some("Ennavale".into()),
            artist: Some("A. R. Rahman".into()),
            album: None,
            duration: Some(309.8),
            elapsed: Some(196.5),
            rate: 1.0,
            state: PlaybackState::Playing,
            timestamp_ms: 1_000_000,
            queue_ids: vec![],
            device_name: Some("iPhone".into()),
            artwork: None,
            volume: None,
            origin: DeviceRole::Iphone,
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: NowPlayingState = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn command_roundtrip() {
        let c = Command::play_store_id("123", 12.5);
        let json = serde_json::to_string(&c).unwrap();
        let back: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(c, back);
    }

    #[test]
    fn effective_elapsed_advances_while_playing() {
        let s = NowPlayingState {
            elapsed: Some(10.0),
            rate: 1.0,
            state: PlaybackState::Playing,
            timestamp_ms: 0,
            duration: Some(100.0),
            ..Default::default()
        };
        assert!((s.effective_elapsed(5000).unwrap() - 15.0).abs() < 1e-6);
    }

    #[test]
    fn effective_elapsed_frozen_while_paused() {
        let s = NowPlayingState {
            elapsed: Some(10.0),
            rate: 0.0,
            state: PlaybackState::Paused,
            timestamp_ms: 0,
            ..Default::default()
        };
        assert!((s.effective_elapsed(9000).unwrap() - 10.0).abs() < 1e-6);
    }

    #[test]
    fn ws_envelope_tagged() {        let m = WsMessage::Command(Command::pause());
        let v: serde_json::Value = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
        assert_eq!(v["type"], "command");
    }

    #[test]
    fn rejects_bad_volume() {
        assert!(Command::volume(0.5).to(DeviceRole::Mac).validate().is_ok());
        assert!(Command::volume(1.5).validate().is_err());
        assert!(Command::volume(f32::NAN).validate().is_err());
        let mut c = Command::play();
        c.action = CommandAction::Volume;
        assert!(c.validate().is_err());
        let s = NowPlayingState { volume: Some(2.0), ..Default::default() };
        assert!(s.validate().is_err());
        let s = NowPlayingState { volume: Some(0.7), ..Default::default() };
        assert!(s.validate().is_ok());
    }

    #[test]
    fn rejects_bad_store_id() {
        let mut s = NowPlayingState { store_id: Some("abc'; DROP".into()), ..Default::default() };
        assert!(s.validate().is_err());
        s.store_id = Some("123".into());
        s.queue_ids = vec!["x".into()];
        assert!(s.validate().is_err());
    }

    #[test]
    fn rejects_oversize_and_nonfinite() {
        let s = NowPlayingState {
            title: Some("x".repeat(600)),
            ..Default::default()
        };
        assert!(s.validate().is_err());
        let s = NowPlayingState { duration: Some(f64::NAN), ..Default::default() };
        assert!(s.validate().is_err());
        assert!(Command::seek(f64::INFINITY).validate().is_err());
        assert!(Command::seek(5.0).validate().is_ok());
        assert!(Command::seek(0.0).validate().is_ok());
    }

    fn playing_at(ts: i64) -> NowPlayingState {
        NowPlayingState {
            state: PlaybackState::Playing,
            rate: 1.0,
            elapsed: Some(5.0),
            timestamp_ms: ts,
            ..Default::default()
        }
    }

    #[test]
    fn active_side_prefers_the_player() {
        let ip = playing_at(1000);
        let mac = playing_at(1000);
        // Only one playing wins regardless of perspective.
        assert_eq!(active_side(Some(&ip), None, DeviceRole::Mac, 2000, 15000), DeviceRole::Iphone);
        assert_eq!(active_side(None, Some(&mac), DeviceRole::Iphone, 2000, 15000), DeviceRole::Mac);
        // Both playing defers to self.
        assert_eq!(
            active_side(Some(&ip), Some(&mac), DeviceRole::Mac, 2000, 15000),
            DeviceRole::Mac
        );
        assert_eq!(
            active_side(Some(&ip), Some(&mac), DeviceRole::Iphone, 2000, 15000),
            DeviceRole::Iphone
        );
        // Neither playing defers to self.
        assert_eq!(active_side(None, None, DeviceRole::Mac, 2000, 15000), DeviceRole::Mac);
        // Stale snapshots never win.
        assert_eq!(
            active_side(Some(&playing_at(-18_000)), Some(&mac), DeviceRole::Iphone, 2000, 15_000),
            DeviceRole::Mac
        );
    }
}
