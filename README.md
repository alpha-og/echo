# Echo — local multi-device media control

Echo syncs playback state and transport control between devices on the
local network. One side publishes Now Playing snapshots to a relay. The
other side renders them and sends commands back.

Apple Music on iOS and macOS is the supported source today. The relay
protocol itself carries generic snapshots and addressed commands, so
additional sources can be added without changing the transport.

## Scope

Supported:

- Platforms: iOS and macOS.
- Source: Apple Music.
- Topology: 2 devices. One iPhone app, one Mac app, one relay on the Mac.

Not supported:

- Other operating systems.
- Other players or system-wide audio capture.
- More than 2 devices.
- Simultaneous synced playback across devices.

## Architecture

Three components, one trust domain (your LAN):

- `src/` — Rust relay (`echo`). Holds the latest snapshot per side, routes
  addressed commands, owns pairing. Snapshots and small cover deltas only.
  No audio passes through it.
- `ios/Echo/` — iOS app. Publishes the phone's Apple Music state via
  `MPMusicPlayerController`, executes commands from the Mac, renders the
  Mac side as a second player.
- `mac/Echo/` — menu-bar app. Publishes the Mac's Music.app state
  (AppleScript), executes commands from the phone, bundles and supervises
  the relay binary.

```
iPhone (Echo) ──WS/HTTP──┐
                         ├─► echo relay :11447 ──► snapshots + commands
Mac (Echo + Music.app) ──┘
```

`src/protocol.rs` is the wire contract both apps implement. The active-side
rule lives there with tests: whoever is playing wins. Ties resolve to the
side that played last, so pausing never flips the display.

## Relay CLI

```sh
cargo run -- serve                         # dual-stack [::]:11447, mDNS on
cargo run -- serve --bind 127.0.0.1:11447  # loopback only (no advertisement)
cargo run -- pair-code                     # current 6-digit code, on demand
cargo run -- status [--role iphone|mac]
cargo run -- send [--to iphone|mac] pause|play|toggle|next|previous|seek|play-id
cargo run -- tail [--role iphone|mac]
```

`send play-id --store-id <id> --position <s>` is the exact-handoff
primitive. It tells the target to queue an Apple Music catalog ID at a
position. Mac to iPhone handoff stays approximate: AppleScript exposes no
catalog IDs for Mac tracks.

## Protocol

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness probe, unauthenticated |
| `GET /status?role=` | Latest snapshot for a side, or `204` when absent/expired |
| `POST /command` | Broadcast a validated command to its target side |
| `POST /pair` | Exchange a 6-digit TOTP code for a session token |
| `DELETE /sessions` | Revoke the caller's session (Unpair) |
| `GET /pair-requests` | Pairing presence (phone knocked / cancel) |
| `GET /ws?role=` | Live channel: send snapshots, receive commands |

Snapshots expire after 30s without a heartbeat. A dead publisher stops
rendering instead of going stale. Cover art is sent as a track-change
delta only (~40KB cap) and held sticky across heartbeats. Every snapshot
and command is validated before it touches shared state. Oversize WS
frames are dropped.

## Auth and pairing

- Loopback callers (this Mac's own app and CLI) are trusted without a token.
- LAN callers present a session token (`Authorization: Bearer` or `?token=`).
- Pairing is TOTP, 6 digits, 30s step. Run `pair-code` on the Mac, or tap
  the phone's pair sheet to pop the code on the Mac automatically. Type it
  into the phone once. The issued token persists in
  `~/.echo/sessions.json` and survives restarts. Idle sessions are reaped
  after 30 days. Pairing attempts are throttled per IP.
- Discovery is mDNS (`_echo._tcp`, OS responder). Manual `IP:port` entry
  remains for networks that block multicast.

## Takeover semantics

Commanding one side pauses the other first. Exactly one side plays at a
time. A later play resumes where that side paused. Takeovers are
transition-gated with a short cooldown in both apps. Heartbeats and
command echoes cannot cause a loop.

## Platform limits (iOS)

iOS suspends background sockets about 30s after the app leaves the screen.
A force-quit app cannot run at all. Both are OS policy. Echo compensates
with an opt-in silent-audio hold ("Stay connected in background",
personal sideload only) plus periodic background refresh. With the toggle
off, sync pauses with the app and resumes on foreground. Free Apple ID
signing requires a weekly reinstall from Xcode (7-day expiry).

## Future scope

- Cross-platform clients. The relay protocol is transport-agnostic, so new
  clients adopt the existing contract.
- Generic media sources and more than 2 devices. Relay state is already
  keyed per side. Addressing must move past the current two roles.
- Party mode. Synchronized playback across devices at the same time.
  Requires shared clock sync. Research-grade, unplanned.
- Media device controls. Output routing and volume alongside transport.

## Troubleshooting

- Port busy or two relays: the menu app owns `:11447` and clears stale
  relays on Start/Restart. A terminal `echo serve` and the menu app fight
  over the port. Run one.
- Phone cannot find the Mac: same Wi-Fi, macOS firewall allowing 11447,
  or enter `IP:11447` manually. `curl http://<mac>:11447/health` must
  reply `ok`.
- Repeated pairing rejection: TOTP throttle is 10 failures per 5 minutes
  per IP. Wait, then re-check the code on the Mac.
- Stale device rows: snapshots expire after 30s. Anything older stops
  rendering on the next poll.

## Development

```sh
cargo test          # relay unit tests (protocol, pairing, validation)
cargo clippy        # lint
# iOS: open ios/Echo/Echo.xcodeproj — personal team, run to device
# Mac: open mac/Echo/Echo.xcodeproj — Run Script phase bundles the relay
```
