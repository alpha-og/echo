//! TOTP pairing: secret, sessions, throttled endpoints.
use axum::{
    Json,
    extract::{ConnectInfo, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use crate::{protocol::now_ms, server::{AppState, bearer}};
use std::io::Write as _;

pub(crate) type PairAttempts = HashMap<IpAddr, (u32, Instant)>;
/// Outstanding pairing requests per IP: when asked and which device.
pub(crate) type PairRequests = HashMap<IpAddr, (Instant, Option<String>)>;

/// Pairing requests stay visible this long.
const PAIR_REQUEST_TTL: Duration = Duration::from_secs(120);

/// TOTP pairing parameters: 6 digits, 30s step, ±1 step skew.
const TOTP_STEP: u64 = 30;
/// Pairing throttle: max failures per window before 429.
const PAIR_MAX_FAILS: u32 = 10;
const PAIR_WINDOW: Duration = Duration::from_secs(300);
fn state_file(name: &str) -> PathBuf {
    if let Ok(d) = std::env::var("ECHO_STATE_DIR") {
        PathBuf::from(d).join(name)
    } else if let Ok(h) = std::env::var("HOME") {
        PathBuf::from(h).join(".echo").join(name)
    } else {
        PathBuf::from(name)
    }
}
fn secret_path() -> PathBuf {
    state_file("totp-secret")
}

/// Persisted `/pair` session tokens. Tokens survive restarts; pairing is a
/// one-time step per device.
fn sessions_path() -> PathBuf {
    state_file("sessions.json")
}
/// Sessions idle past this TTL are stale and pruned.
pub(crate) const SESSION_IDLE_TTL: Duration = Duration::from_secs(30 * 24 * 3600);

pub(crate) fn load_sessions() -> HashMap<String, Instant> {
    let p = sessions_path();
    let Ok(txt) = std::fs::read_to_string(&p) else {
        return HashMap::new();
    };
    let Ok(list): Result<Vec<String>, _> = serde_json::from_str(&txt) else {
        warn!("sessions file unreadable, starting unpaired");
        return HashMap::new();
    };
    let now = Instant::now();
    list.into_iter()
        .filter(|t| t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(|t| (t, now))
        .collect()
}
pub(crate) fn save_sessions(sessions: &HashMap<String, Instant>) {
    let p = sessions_path();
    let list: Vec<&String> = sessions.keys().collect();
    let Ok(txt) = serde_json::to_string(&list) else {
        return;
    };
    if let Some(parent) = p.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&p)
        {
            let _ = f.write_all(txt.as_bytes());
        }
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::write(&p, txt);
    }
}
fn hex_encode(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn hex_decode(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) || s.is_empty() || s.len() > 128 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

/// Load the persisted TOTP secret or create one (0600 on unix).
pub(crate) fn load_or_create_secret() -> anyhow::Result<Vec<u8>> {
    let p = secret_path();
    if let Ok(txt) = std::fs::read_to_string(&p) {
        if let Some(raw) = hex_decode(&txt) {
            if raw.len() >= 16 {
                return Ok(raw);
            }
            warn!("totp secret too short, regenerating");
        } else {
            warn!("totp secret unreadable, regenerating");
        }
    }
    let raw: [u8; 20] = rand::random();
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&p)?
            .write_all(hex_encode(&raw).as_bytes())?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&p, hex_encode(&raw))?;
    }
    info!("created new totp secret at {}", p.display());
    Ok(raw.to_vec())
}
pub(crate) fn totp_for(secret: &[u8]) -> anyhow::Result<totp_rs::TOTP> {
    totp_rs::TOTP::new(totp_rs::Algorithm::SHA1, 6, 1, TOTP_STEP, secret.to_vec())
        .map_err(|e| anyhow::anyhow!("totp init: {e}"))
}
pub(crate) fn issue_token() -> String {
    hex_encode(&rand::random::<[u8; 16]>())
}

/// Loopback callers (this Mac's own CLI / menu app) are trusted.
/// LAN callers must present a `/pair` session token.
pub(crate) async fn pair_code() -> anyhow::Result<()> {
    let secret = load_or_create_secret()?;
    let totp = totp_for(&secret)?;
    let now = now_ms() / 1000;
    let remain = (TOTP_STEP - (now as u64 % TOTP_STEP)) as i64;
    println!("pairing code: {}  (valid {remain}s)", totp.generate_current()?);
    Ok(())
}

#[derive(serde::Deserialize)]
pub(crate) struct PairReq {
    code: String,
}

/// Revoke the caller's own session (used by Unpair). Best-effort from the
/// phone: it presents the token once, then wipes it locally regardless.
pub(crate) async fn delete_session(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let mut presented = Vec::new();
    if let Some(t) = q.get("token") {
        presented.push(t.clone());
    }
    if let Some(h) = headers.get("authorization").and_then(|v| v.to_str().ok())
        && let Some(tok) = h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("bearer "))
    {
        presented.push(tok.trim().to_string());
    }
    let mut revoked = false;
    if !presented.is_empty() {
        let mut sessions = st.sessions.write().await;
        for p in presented {
            if sessions.remove(p.as_str()).is_some() {
                revoked = true;
            }
        }
        if revoked {
            save_sessions(&sessions);
        }
    }
    if revoked {
        info!("session revoked by owner");
        (StatusCode::OK, Json(serde_json::json!({"revoked": true}))).into_response()
    } else {
        (StatusCode::NOT_FOUND, Json(serde_json::json!({"revoked": false}))).into_response()
    }
}
#[derive(serde::Deserialize)]
pub(crate) struct PairRequestReq {
    device: Option<String>,
}

/// Phone requested pairing: record who asked so the menu can present the
/// code. Unauthenticated by necessity (the phone holds no token yet);
/// entries are throttled and short-lived, and the code is still required
/// to complete pairing.
pub(crate) async fn post_pair_request(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(req): Json<PairRequestReq>,
) -> impl IntoResponse {
    if let Some(d) = &req.device
        && d.len() > 64
    {
        return (StatusCode::BAD_REQUEST, "device name too long").into_response();
    }
    let mut m = st.pair_requests.lock().await;
    m.retain(|_, (t, _)| t.elapsed() < PAIR_REQUEST_TTL);
    // One outstanding request per IP; repeat requests refresh the timer.
    m.insert(addr.ip(), (Instant::now(), req.device.clone()));
    if m.len() > 32 {
        m.clear();
    }
    info!(%addr, "pair requested");
    (StatusCode::OK, Json(serde_json::json!({"ok": true}))).into_response()
}
pub(crate) async fn delete_pair_request(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> impl IntoResponse {
    st.pair_requests.lock().await.remove(&addr.ip());
    (StatusCode::OK, Json(serde_json::json!({"ok": true}))).into_response()
}

/// Answered by the menu app over loopback: whether a pairing request is
/// pending, and which device asked last.
pub(crate) async fn get_pair_requests(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> impl IntoResponse {
    if !bearer(&headers, &q, addr, &st) {
        return (StatusCode::UNAUTHORIZED, "unpaired device").into_response();
    }
    let mut m = st.pair_requests.lock().await;
    m.retain(|_, (t, _)| t.elapsed() < PAIR_REQUEST_TTL);
    let device = m.values().last().and_then(|(_, d)| d.clone());
    let pending = !m.is_empty();
    (StatusCode::OK, Json(serde_json::json!({"pending": pending, "device": device}))).into_response()
}
pub(crate) async fn post_pair(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(req): Json<PairReq>,
) -> impl IntoResponse {
    let ip = addr.ip();
    // Throttle: 10 failures per 5 minutes per IP.
    {
        let mut m = st.pair_attempts.lock().await;
        m.retain(|_, (_, t)| t.elapsed() < PAIR_WINDOW);
        if m.get(&ip).map(|(n, _)| *n >= PAIR_MAX_FAILS).unwrap_or(false) {
            warn!(%addr, "pair rejected: throttled");
            return (StatusCode::TOO_MANY_REQUESTS, "too many attempts, try again later")
                .into_response();
        }
    }
    let code = req.code.trim().replace([' ', '-'], "");
    if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
        warn!(%addr, "pair rejected: malformed code");
        return (StatusCode::BAD_REQUEST, "code must be 6 digits").into_response();
    }
    if !st.totp.check_current(&code).unwrap_or(false) {
        let mut m = st.pair_attempts.lock().await;
        let e = m.entry(ip).or_insert((0, Instant::now()));
        e.0 += 1;
        if e.0 == 1 {
            e.1 = Instant::now();
        }
        warn!(%addr, "pair rejected: wrong code");
        return (StatusCode::UNAUTHORIZED, "wrong code").into_response();
    }
    let token = issue_token();
    {
        let mut sessions = st.sessions.write().await;
        sessions.insert(token.clone(), Instant::now());
        save_sessions(&sessions);
    }
    // Paired: the request is fulfilled, hide the popup.
    st.pair_requests.lock().await.remove(&addr.ip());
    info!(%addr, "pair ok: session issued");
    (StatusCode::OK, Json(serde_json::json!({"token": token}))).into_response()
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totp_rfc6238_vector() {
        // RFC 6238 Appendix B: secret "12345678901234567890", T=59s -> 94287082 (8-digit).
        let totp = totp_for(b"12345678901234567890").unwrap();
        assert_eq!(totp.generate(59), "287082");
    }

    #[test]
    fn hex_roundtrip() {
        let raw = b"hello-echo-test-bytes!";
        assert_eq!(hex_decode(&hex_encode(raw)).unwrap(), raw);
        assert!(hex_decode("zz").is_none());
        assert!(hex_decode("abc").is_none());
    }

    #[test]
    fn issued_tokens_unique_and_sized() {
        let a = issue_token();
        let b = issue_token();
        assert_eq!(a.len(), 32);
        assert_ne!(a, b);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
    }
}
