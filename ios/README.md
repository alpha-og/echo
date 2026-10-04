# Echo for iOS — first sideload

Requirements: a Mac with Xcode, a free Apple ID, an iPhone on the same
Wi-Fi, and the relay running on the Mac (`cargo run -- serve`, or the
menu-bar app, which supervises it).

## What the app touches

Only two things: the `ws://<your-mac-ip>:11447` relay you pair with, and
on-device Apple Music via `MediaPlayer`. No third-party hosts, no
location, microphone, keychain, or iCloud usage.

## 0. Start the relay on the Mac

```sh
cargo run -- serve --bind 0.0.0.0:11447
# note the Mac's LAN IP: ipconfig getifaddr en0
```

The pairing code is shown on demand (`cargo run -- pair-code`) or pops up
in the menu-bar app when the phone requests pairing.

## 1. Xcode one-time setup

1. Xcode → Settings → Accounts → add your Apple ID (free tier works).
2. Connect the iPhone via USB → Trust This Computer on the phone.
3. iPhone → Settings → Privacy & Security → Developer Mode → On (reboots once).
4. The Xcode run-destination list should now include the iPhone. If not,
   check Window → Devices and Simulators.

## 2. Open the project (no manual wiring)

1. Open `ios/Echo/Echo.xcodeproj`. Sources, `MediaPlayer` linkage, the
   music-usage string, local-network and background keys, and the launch
   screen are already in the repo.
2. Target → Signing → your Personal Team, automatic signing. Use the Fix
   button for anything red.

## 3. First install (one expected failure)

1. Run (Cmd-R) with the iPhone selected. The build succeeds; installation
   fails with Untrusted Developer on a first-time dev phone.
2. iPhone → Settings → General → VPN & Device Management → your Apple
   ID → Trust. Run again.
3. Accept the Apple Music permission prompt.
4. Tap the Mac under Nearby Macs (Bonjour; no typing), enter the 6-digit
   code, Pair once, then Connect. Manual `IP:port` entry is the fallback
   for networks that block multicast.
5. Play Apple Music. The Mac side appears as a second player tab.

## Background behavior

With "Stay connected in background" on (default), sync survives lock and
app-switch via a silent-audio hold. With it off, iOS suspends the socket
shortly after leaving the app and sync resumes on foreground. A
force-quit app never syncs — relaunch it. See the root README for details.

## Limits of free signing

Re-run from Xcode roughly every 7 days (a few sideloaded apps max). A
paid developer account removes the expiry; the code is unchanged.

## Troubleshooting

- `No code signature found` → wrong signing team or unregistered phone;
  let Xcode fix it.
- App opens then closes → stale install; clean-install from Xcode again.
- Connect spins, Mac sees nothing → different Wi-Fi networks, macOS
  firewall blocking 11447, or wrong Mac IP. From another device:
  `curl http://<mac-ip>:11447/health` should reply `ok`.
- Stops updating when locked → background hold is off, or the app was
  force-quit.
