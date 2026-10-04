// Handoff-to-Mac helper: play an Apple Music catalog track at a position.
//
// Usage:
//   swiftc -o handoff-to-mac handoff-to-mac.swift
//   ./handoff-to-mac --store-id 123456789 --position 83.5
//
// Strategy: open the track URL in Music.app, then seek via AppleScript.
// Requires the Mac to be signed into the same Apple ID / Apple Music.
import Foundation
import AppKit

func usage() -> Never {
    fputs("usage: handoff-to-mac --store-id <id> [--position <sec>]\n", stderr)
    exit(2)
}

var storeID: String?
var position: Double = 0
var i = 1
while i < CommandLine.arguments.count {
    let a = CommandLine.arguments[i]
    if a == "--store-id", i + 1 < CommandLine.arguments.count { storeID = CommandLine.arguments[i+1]; i += 2 }
    else if a == "--position", i + 1 < CommandLine.arguments.count { position = Double(CommandLine.arguments[i+1]) ?? 0; i += 2 }
    else { usage() }
}
guard let sid = storeID, !sid.isEmpty else { usage() }
// Validate: catalog ids are 1-20 ASCII digits. Rejects URL/AppleScript injection.
guard sid.count <= 20 && sid.allSatisfy({ $0.isNumber && $0.isASCII }) else {
    fputs("error: --store-id must be 1-20 ASCII digits\n", stderr)
    exit(2)
}
guard position.isFinite && position >= 0 && position <= 86400 else {
    fputs("error: --position must be 0..86400\n", stderr)
    exit(2)
}

// music.apple.com song URL opens the exact catalog track in Music.app.
let urlStr = "https://music.apple.com/us/song/\(sid)?i=\(sid)"
guard let url = URL(string: urlStr) else { exit(1) }
NSWorkspace.shared.open(url)

// Give Music a moment to load the track, then seek + ensure playing.
sleep(2)
let seekScript = """
tell application "Music"
  try
    set player position to \(position)
    play
  end try
end tell
"""
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
proc.arguments = ["-e", seekScript]
try? proc.run()
proc.waitUntilExit()
print("handoff-to-mac: opened \(sid) at \(position)s (Music exit \(proc.terminationStatus))")
