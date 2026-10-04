# Echo — Apple Music sync between iPhone and Mac

Echo keeps Apple Music in sync between an iPhone and a Mac over the local
network: live Now Playing on both sides, transport control in either
direction, and exact handoff (same track, same position).

## Architecture

Three components, one trust domain (your LAN):

- `src/` — Rust relay (`echo`). Holds the latest snapshot per side, routes
  addressed commands, owns pairing. No audio passes through it; snapshots
  and small cover deltas only.
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
rule lives there with tests: whoever is playing wins; ties resolve to the
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

`send play-id --store-id <id> --position <s>` is the exact-handoff primitive:
it tells the target to queue an Apple Music catalog ID at a position.

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

Snapshots expire after 30s without a heartbeat, so a dead publisher stops
rendering instead of going stale. Cover art is sent as a track-change delta
only (~40KB cap) and held sticky across heartbeats. Every snapshot and
command is validated before it touches shared state; oversize WS frames are
dropped.

## Auth and pairing

- Loopback callers (this Mac's own app and CLI) are trusted without a token.
- LAN callers present a session token (`Authorization: Bearer` or `?token=`).
- Pairing is TOTP, 6 digits, 30s step: run `pair-code` on the Mac (or tap
  the phone's pair sheet, which pops the code on the Mac automatically) and
  type it into the phone once. The issued token persists in
  `~/.echo/sessions.json` (survives restarts) and idle sessions are reaped
  after 30 days. Pairing attempts are throttled per IP.
- Discovery is mDNS (`_echo._tcp`, OS responder); manual `IP:port` entry
  remains for networks that block multicast.

## Takeover semantics

Commanding one side pauses the other first, so exactly one side plays.
A later play resumes where that side paused. Takeovers are transition-gated
with a short cooldown in both apps, so heartbeats and command echoes can
never ping-pong. Dual simultaneous playback is out of scope by design.

## Platform limits (iOS)

iOS suspends background sockets ~30s after the app leaves the screen, and a
force-quit app cannot run at all — both are OS policy, not bugs. Echo
compensates with an opt-in silent-audio hold ("Stay connected in
background", personal sideload only; App Store review rejects silent audio)
plus periodic background refresh. With the toggle off, sync pauses with the
app and resumes on foreground. Free Apple ID signing requires a weekly
re-install from Xcode (~7-day expiry).

## Troubleshooting

- Port busy or two relays: the menu app owns `:11447` and clears stale
  relays on Start/Restart. A terminal `echo serve` and the menu app will
  fight over the port — run one.
- Phone can't find the Mac: same Wi-Fi, macOS firewall allowing 11447, or
  enter `IP:11447` manually. `curl http://<mac>:11447/health` should reply `ok`.
- Pairing rejected repeatedly: TOTP throttle is 10 failures per 5 minutes
  per IP — wait, then re-check the code on the Mac.
- Stale device rows: snapshots expire after 30s; anything older stops
  rendering on the next poll.

## Development

```sh
cargo test          # relay unit tests (protocol, pairing, validation)
cargo clippy        # lint
# iOS: open ios/Echo/Echo.xcodeproj — personal team, run to device
# Mac: open mac/Echo/Echo.xcodeproj — Run Script phase bundles the relay
```
