# cbm

A clipboard manager for macOS, built for a small resident footprint and — the
priority that shaped most decisions here — a low CPU cost while idle.

Press **⌘⌥C**, type, press **↵**. The entry goes back on the clipboard and is
pasted into the app you came from.

## Status

Working first version. Text, rich text, images and file selections are captured;
search, preview, paste-back, retention limits and live metrics all work.

## Requirements

macOS 14 or later. Swift toolchain (Command Line Tools are enough — full Xcode is
not required, and nothing here uses `xcodebuild`).

## Build and run

```bash
make run
```

Builds, assembles `~/Applications/cbm.app`, signs it, and launches it. Other
targets:

| Target | What it does |
|---|---|
| `make test` | runs the logic self-tests |
| `make status` | prints signing state, Accessibility state and data location |
| `make build` | compiles only |
| `make cert` | creates a stable signing identity (see *Accessibility* below) |
| `make stop` | quits a running instance |
| `make uninstall` | removes the app, leaves history intact |

`CONFIG=debug make run` builds unoptimised.

## Keys

| Key | Action |
|---|---|
| ⌘⌥C | open the panel (again to close) |
| type | fuzzy search |
| ↑ ↓ | move |
| ↵ | paste into the previous app |
| ⌘↵ | copy to clipboard only |
| ⇧⌘↵ | paste as plain text |
| ⌘⌫ | delete the entry |
| ⌘, | settings |
| esc | close |

`app:safari` in the query narrows to entries copied from that application, and
combines with search terms: `app:safari github`.

## Accessibility

Pressing ⌘V for you requires the Accessibility permission. Without it everything
still works — ↵ puts the entry on the clipboard and you press ⌘V yourself. The
panel footer says which mode you are in.

**Run `make cert` before granting it.** macOS ties a permission to an app's code
signature, not to its path. Without a signing identity the app is ad-hoc signed,
which means its signature is just a hash of the binary — so every rebuild looks
like a different app to macOS and silently voids the grant, even though the
switch in the Accessibility list still appears to be on. This is why properly
signed apps let you click *Later* and keep working, and an ad-hoc build does not.

`make cert` mints a free self-signed code-signing certificate named `cbm-dev`,
imports it into your login keychain and marks it trusted for code signing (one
system authentication dialog). After that the signature is stable and the grant
survives rebuilds. To undo it: delete `cbm-dev` in Keychain Access and `rm -rf
certs/`.

Separately, if a fresh grant still is not picked up, Settings has a *Restart cbm*
button.

## Where things are

```
~/Library/Application Support/cbm/
  history.sqlite3     metadata, and payloads under 64 KiB
  blobs/              larger payloads, keyed by SHA-256 (deduplicated)
  thumbs/             256px thumbnails
```

All 0600. No encryption: FileVault already covers the disk, and per-row crypto
would make search unusable for no real gain against an attacker who can read
your home directory anyway.

Passwords never arrive here. Password managers mark their clipboard writes with
`org.nspasteboard.ConcealedType` and similar conventions, and those are skipped
before anything is read.

## How the CPU cost is kept down

`NSPasteboard` has no change notification, so every clipboard manager polls
`changeCount`. That poll is a cross-process call, and what it really costs is not
CPU percentage but **wakeups** — each one keeps the core out of its deep idle
state. So:

- **Timer leeway.** A `DispatchSourceTimer` with 30 % leeway lets the kernel
  merge our wakeup with wakeups other processes already scheduled, which often
  makes ours free.
- **Cadence derived from the signal we already poll.** Copies arrive in bursts:
  200 ms for five seconds after a change, 500 ms normally, 2 s once nothing has
  happened for a minute. No extra API call is needed to decide this.
- **Immediate polls on the events that matter** — opening the panel, switching
  apps, waking — so a slow cadence never means stale contents.
- **Fully suspended** while the screen is locked or the machine is asleep.
- **Lazy AppKit.** No window, table view or text system is created until the
  hotkey is pressed for the first time.
- **No vibrancy.** The translucent launcher look makes the window server blur
  everything behind the panel on every frame it is open.
- **Bounded caches.** 8 MB of thumbnails, a 2 MB SQLite page cache, 256-byte
  searchable snippets. Full-size images are read only for the preview and the
  paste, never for the list.

Search stays instant through a per-entry character bitmask that rejects most
candidates with one AND, and through incremental narrowing: a growing query
rescores only the previous result set, which is exact rather than approximate,
because adding a character to a subsequence query can only remove matches.

## Measured

On an Apple Silicon Mac, this build:

- **0.03 s of CPU time over 90 s idle** — 0.033 %.
- **~26 MB** reported memory (`phys_footprint`) with the panel and settings
  window both built.

Settings shows these live — memory, wakeups per second, clipboard reads and the
last search duration — so the claims above can be checked rather than believed.

## Not in this version

Pinned favourites, a per-app ignore list, snippets, sync, encryption, and a
configurable hotkey (⌘⌥C is fixed).

## Known limitations

- **Source attribution is a heuristic.** We learn about a clipboard change up to
  one poll interval after it happens, so switching apps inside that window can
  attribute an entry to the wrong application.
- **Tests live in the app binary** behind `--self-test`, because XCTest and
  swift-testing both ship with Xcode and this machine has only the Command Line
  Tools. Moving them to a proper test target needs a library/executable split and
  nothing else.
