//! Relay HTTP + WebSocket server: per-side state, addressed commands.
use axum::{
    Json, Router,
    extract::{ConnectInfo, Query, State, ws::{Message, WebSocket, WebSocketUpgrade}},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use futures::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, atomic::{AtomicUsize, Ordering}},
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, RwLock, broadcast};
use tracing::{info, warn};
use crate::{pairing::{delete_pair_request, delete_session, get_pair_requests, load_or_create_secret, load_sessions, post_pair, post_pair_request, totp_for}, protocol::{Command, DeviceRole, NowPlayingState, WsMessage, now_ms}};
use crate::pairing::{PairAttempts, PairRequests};

/// Snapshots older than this are treated as gone (publisher quit/crashed).
/// Both apps heartbeat every ~2s while alive, so 30s is long dead.
pub(crate) const STATE_TTL_MS: i64 = 30_000;

fn fresh(s: Option<NowPlayingState>) -> Option<NowPlayingState> {
    s.filter(|x| now_ms() - x.timestamp_ms <= STATE_TTL_MS)
}

/// Max WS text frame we process (DoS cap; HTTP JSON already capped by axum).
const MAX_WS_BYTES: usize = 64 * 1024;
/// Snapshot older than this is flagged stale in `status`.
pub(crate) const STALE_MS: i64 = 15_000;
#[derive(Clone)]
pub(crate) struct AppState {
    /// Latest snapshot per device side.
    pub(crate) latest_iphone: Arc<RwLock<Option<NowPlayingState>>>,
    pub(crate) latest_mac: Arc<RwLock<Option<NowPlayingState>>>,
    pub(crate) state_tx: broadcast::Sender<NowPlayingState>,
    pub(crate) cmd_tx: broadcast::Sender<Command>,
    /// Live iPhone publishers. Sized to connections, not handshakes, so the
    /// `delivered` count in `/command` responses stays exact.
    pub(crate) iphone_count: Arc<AtomicUsize>,
    /// TOTP verifier for pairing codes shown on the Mac terminal.
    pub(crate) totp: Arc<totp_rs::TOTP>,
    /// Session tokens issued via `/pair`, persisted to disk. The only LAN credential.
    pub(crate) sessions: Arc<RwLock<HashMap<String, Instant>>>,
    /// Failed `/pair` attempts per IP (count, window start) for throttling.
    pub(crate) pair_attempts: Arc<Mutex<PairAttempts>>,
    /// Live pairing requests: IP -> (when asked, device name). Shown in a
    /// popup, expire fast.
    pub(crate) pair_requests: Arc<Mutex<PairRequests>>,
}

/// Outstanding pairing attempts per IP: count and window start.
pub(crate) fn bearer(headers: &HeaderMap, q: &HashMap<String, String>, addr: SocketAddr, st: &AppState) -> bool {
    if addr.ip().is_loopback() {
        return true;
    }
    let mut presented = Vec::new();
    if let Some(t) = q.get("token") {
        presented.push(t.clone());
    }
    if let Some(h) = headers.get("authorization").and_then(|v| v.to_str().ok())
        && let Some(tok) = h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("bearer "))
    {
        presented.push(tok.trim().to_string());
    }
    if presented.is_empty() {
        return false;
    }
    // Touch on use: sessions idle past the TTL are stale entries from
    // wiped or reinstalled phones.
    if let Ok(mut sessions) = st.sessions.try_write() {
        let now = Instant::now();
        if presented.iter().any(|p| sessions.contains_key(p)) {
            for p in &presented {
                sessions.insert(p.clone(), now);
            }
            return true;
        }
        return false;
    }
    st.sessions
        .try_read()
        .map(|sessions| presented.iter().any(|p| sessions.contains_key(p)))
        .unwrap_or(false)
}
/// Advertise `_echo._tcp` through the OS mDNS responder, so phones find the
/// relay without manual IP entry. The returned handle must stay alive —
/// dropping it unpublishes. Non-fatal: manual IP entry still works.
#[cfg(target_os = "macos")]
fn advertise_mdns(port: u16) -> Option<dns_sd::DNSService> {
    let host = hostname::get()
        .map(|h| {
            h.to_string_lossy()
                .trim_end_matches(".local")
                .to_owned()
        })
        .map(|h| if h.is_empty() { "Mac".to_owned() } else { h })
        .unwrap_or_else(|_| "Mac".into());
    // Plain ASCII: non-ASCII instance names break some browsers.
    let instance = format!("{host} echo");
    match dns_sd::DNSService::register(
        Some(&instance),
        "_echo._tcp",
        None,
        None,
        port,
        &["v=1"],
    ) {
        Ok(svc) => {
            // Address resolution stays with the OS responder.
            info!("advertising '{instance}' on port {port} (_echo._tcp)");
            Some(svc)
        }
        Err(e) => {
            warn!("mDNS unavailable: {e}");
            None
        }
    }
}

/// Non-macOS: no advertisement yet (manual IP entry).
#[cfg(not(target_os = "macos"))]
fn advertise_mdns(_port: u16) -> Option<()> {
    warn!("mDNS advertisement is macOS-only for now; use manual IP entry");
    None
}
pub(crate) async fn serve(bind: &str) -> anyhow::Result<()> {
    let secret = load_or_create_secret()?;
    let totp = Arc::new(totp_for(&secret)?);
    let sessions = Arc::new(RwLock::new(load_sessions()));
    let (state_tx, _) = broadcast::channel::<NowPlayingState>(64);
    let (cmd_tx, _) = broadcast::channel::<Command>(64);
    let st = AppState {
        latest_iphone: Arc::new(RwLock::new(None)),
        latest_mac: Arc::new(RwLock::new(None)),
        state_tx,
        cmd_tx,
        iphone_count: Arc::new(AtomicUsize::new(0)),
        totp,
        sessions: sessions.clone(),
        pair_attempts: Arc::new(Mutex::new(HashMap::new())),
        pair_requests: Arc::new(Mutex::new(HashMap::new())),
    };
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/status", get(get_status))
        .route("/command", post(post_command))
        .route("/pair", post(post_pair))
        .route("/sessions", axum::routing::delete(delete_session))
        .route("/pair-requests", post(post_pair_request).delete(delete_pair_request).get(get_pair_requests))
        .route("/ws", get(ws_handler))
        .with_state(st);
    let listener = tokio::net::TcpListener::bind(bind).await?;
    let port = listener.local_addr()?.port();
    info!("echo relay on {}", listener.local_addr()?);
    let _mdns = if bind.starts_with("127.") || bind.starts_with("[::1]") {
        info!("loopback bind: skipping mDNS advertisement");
        None
    } else {
        advertise_mdns(port)
    };
    info!("pairing: run `echo pair-code` on this Mac, type it into the phone");
    // Reaper: sessions idle past the TTL belong to wiped or reinstalled
    // phones and are pruned hourly.
    {
        let sessions = sessions.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(3600)).await;
                let mut s = sessions.write().await;
                let before = s.len();
                s.retain(|_, t| t.elapsed() < crate::pairing::SESSION_IDLE_TTL);
                if s.len() != before {
                    crate::pairing::save_sessions(&s);
                    info!("pruned {} idle sessions", before - s.len());
                }
            }
        });
    }
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;
    Ok(())
}
async fn get_status(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    if !bearer(&headers, &q, addr, &st) {
        warn!("GET /status 401 (unpaired device)");
        return (StatusCode::UNAUTHORIZED, "unpaired device: pair from the app first").into_response();
    }
    let side = q.get("role").map(|r| r.as_str()).unwrap_or("iphone");
    let cur = fresh(match side {
        "mac" => st.latest_mac.read().await.clone(),
        _ => st.latest_iphone.read().await.clone(),
    });
    match cur {
        Some(s) => (StatusCode::OK, Json(serde_json::to_value(s).unwrap())).into_response(),
        // 204 must carry no body — a message here breaks connection reuse.
        None => StatusCode::NO_CONTENT.into_response(),
    }
}
async fn post_command(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
    Json(cmd): Json<Command>,
) -> impl IntoResponse {
    if !bearer(&headers, &q, addr, &st) {
        warn!("POST /command 401 (unpaired device)");
        return (StatusCode::UNAUTHORIZED, "unpaired device: pair from the app first").into_response();
    }
    if let Err(e) = cmd.validate() {
        warn!("rejected command: {e}");
        return (StatusCode::BAD_REQUEST, format!("invalid command: {e}")).into_response();
    }
    let n = st.cmd_tx.send(cmd).unwrap_or(0);
    (StatusCode::OK, Json(serde_json::json!({"delivered": n}))).into_response()
}
async fn ws_handler(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let role = q.get("role").cloned().unwrap_or_else(|| "mac".into());
    if role != "iphone" && role != "mac" {
        warn!(%addr, role = role.as_str(), "ws rejected: bad role");
        return (StatusCode::BAD_REQUEST, "role must be iphone|mac").into_response();
    }
    if !bearer(&headers, &q, addr, &st) {
        warn!(%addr, role = role.as_str(), "ws rejected: unpaired device");
        return (StatusCode::UNAUTHORIZED, "unpaired device: pair from the app first").into_response();
    }
    info!(%addr, role = role.as_str(), "ws handshake ok");
    ws.on_upgrade(move |socket| handle_ws(socket, st, role, addr))
}
fn role_of(role: &str) -> DeviceRole {
    match role {
        "iphone" => DeviceRole::Iphone,
        "mac" => DeviceRole::Mac,
        _ => DeviceRole::Unknown,
    }
}
async fn store_state(st: &AppState, mut s: NowPlayingState) {
    // Sticky artwork: publishers send cover deltas only on track change, so a
    // heartbeat without art must not wipe the stored cover. Carry it over for
    // the same track (store_id when present, else title+artist).
    let prev = match s.origin {
        DeviceRole::Mac => st.latest_mac.read().await.clone(),
        _ => st.latest_iphone.read().await.clone(),
    };
    if s.artwork.is_none() && let Some(p) = prev {
        let same = match (&s.store_id, &p.store_id) {
            (Some(a), Some(b)) => a == b,
            _ => s.title == p.title && s.artist == p.artist,
        };
        if same {
            s.artwork = p.artwork;
        }
    }    match s.origin {
        DeviceRole::Mac => *st.latest_mac.write().await = Some(s),
        _ => *st.latest_iphone.write().await = Some(s),
    }
}
async fn handle_ws(socket: WebSocket, st: AppState, role: String, addr: SocketAddr) {
    let is_iphone = role == "iphone";
    if is_iphone {
        st.iphone_count.fetch_add(1, Ordering::Relaxed);
    }
    info!(%addr, role = role.as_str(), "ws connected");
    let _guard = IphoneGuard(st.iphone_count.clone(), is_iphone);
    let (mut sink, mut stream) = socket.split();
    let mut cmd_rx = st.cmd_tx.subscribe();
    let mut state_rx = st.state_tx.subscribe();

    // Snapshot both sides so the newcomer sees every device immediately.
    for cur in [st.latest_iphone.read().await.clone(), st.latest_mac.read().await.clone()]
        .into_iter()
        .filter_map(fresh)
    {
        if let Ok(txt) = serde_json::to_string(&WsMessage::State(cur)) {
            let _ = sink.send(Message::Text(txt)).await;
        }
    }

    // States flow to everyone (sides ignore their own origin for display).
    // Commands flow only to their target side; `Unknown` means legacy iphone.
    let want_command = move |c: &Command| {
        c.addressed_to(if is_iphone { DeviceRole::Iphone } else { DeviceRole::Mac })
    };
    let forward = async {
        loop {
            tokio::select! {
                Ok(s) = state_rx.recv() => {
                    if let Ok(txt) = serde_json::to_string(&WsMessage::State(s))
                        && sink.send(Message::Text(txt)).await.is_err()
                    {
                        break;
                    }
                }
                Ok(c) = cmd_rx.recv() => {
                    if !want_command(&c) {
                        continue;
                    }
                    if let Ok(txt) = serde_json::to_string(&WsMessage::Command(c))
                        && sink.send(Message::Text(txt)).await.is_err()
                    {
                        break;
                    }
                }
            }
        }
    };

    let st2 = st.clone();
    let role2 = role.clone();
    let backward = async move {
        while let Some(Ok(msg)) = stream.next().await {
            let txt = match msg {
                Message::Text(t) => t,
                Message::Close(_) => break,
                _ => continue,
            };
            if txt.len() > MAX_WS_BYTES {
                warn!("dropped oversize WS frame ({} bytes)", txt.len());
                continue;
            }
            match serde_json::from_str::<WsMessage>(&txt) {
                Ok(WsMessage::State(mut s)) => {
                    if let Err(e) = s.validate() {
                        warn!("rejected state: {e}");
                        continue;
                    }
                    // Origin comes from the authenticated connection role, not the payload.
                    s.origin = role_of(&role2);
                    store_state(&st2, s.clone()).await;
                    let _ = st2.state_tx.send(s);
                }
                Ok(WsMessage::Command(c)) => {
                    if let Err(e) = c.validate() {
                        warn!("rejected command: {e}");
                        continue;
                    }
                    let _ = st2.cmd_tx.send(c);
                }
                Ok(WsMessage::Hello { .. }) => {}
                Err(_) => {
                    if let Ok(mut s) = serde_json::from_str::<NowPlayingState>(&txt) {
                        if let Err(e) = s.validate() {
                            warn!("rejected bare state: {e}");
                        } else {
                            s.origin = role_of(&role2);
                            store_state(&st2, s.clone()).await;
                            let _ = st2.state_tx.send(s);
                        }
                    } else if let Ok(c) = serde_json::from_str::<Command>(&txt) {
                        if let Err(e) = c.validate() {
                            warn!("rejected bare command: {e}");
                        } else {
                            let _ = st2.cmd_tx.send(c);
                        }
                    }
                }
            }
        }
    };

    tokio::select! {
        _ = forward => {},
        _ = backward => {},
    }
    info!(%addr, role = role.as_str(), "ws disconnected");
}

/// Decrements iphone_count on WS exit.
struct IphoneGuard(Arc<AtomicUsize>, bool);
impl Drop for IphoneGuard {
    fn drop(&mut self) {
        if self.1 {
            self.0.fetch_sub(1, Ordering::Relaxed);
        }
    }
}
