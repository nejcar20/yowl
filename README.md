# Yowl — MacBook theft alarm

A menu-bar alarm that makes stealing your MacBook loud.

Free and open source (MIT). No accounts, no analytics, no servers.

Arm it when you leave your laptop on a café table. If someone unplugs the
charger, closes the lid, or picks the machine up, it screams at full volume —
over mute, over headphones — locks the screen, and photographs whoever is
in front of it. Only unlocking your Mac stops it.

## What it is not

This is a deterrent, not a recovery system. **Turn on Find My and FileVault** —
those are what actually recover or protect a stolen Mac. Yowl makes the
theft loud and public, which is a different job.

## Triggers

| Trigger | Default | Notes |
|---|---|---|
| **Charger unplugged** | on | The classic. Needs the charger plugged in to arm. |
| **Laptop is moved** | off | Camera-based. Distinguishes the machine moving from people walking past it. |
| **Lid closed part-way** | off | Reads the hinge sensor, so it fires ~80° before the lid shuts. |

Motion and lid are off by default because each can fire in ordinary use —
closing your own laptop is not theft.

## When it fires

- **Siren** at forced maximum volume, out of the built-in speakers, overriding
  mute and any connected headphones.
- **Screen lock**, so nobody browses your open session while it screams.
- **Photographs** (optional) of whoever is there, including the ten seconds
  *before* the alarm — often the more useful shot, since it catches someone
  walking up rather than the back of their head.
- **A push to your phone** (optional) with the photos, via your own private
  ntfy.sh link.

## Why the source is open

The app asks for your camera and can send photographs to your phone. You are
being asked to trust a stranger's binary with that. The source is here so you
do not have to — you can check the two claims that matter in about a minute:

```bash
# All networking. One implementation, and the one line that builds it.
grep -rn "URLSession\|NWConnection\|CFStream" Sources/
#   Sources/AlarmCore/Alerts/AlertTransport.swift  — the only HTTP client
#   Sources/AlarmApp/AppModel.swift                — constructs it, once

# What the shipped app is actually allowed to do.
codesign -d --entitlements - /Applications/Yowl.app
#   com.apple.security.device.camera
#   com.apple.security.network.client
```

That client is used in exactly one place: sending an alert to the ntfy link you
chose, and only when you have switched phone alerts on. There is no other
network code, no analytics SDK, and no telemetry to find.

## Privacy

No accounts, no analytics, no servers of our own. Photographs are written to
`~/Library/Application Support/Yowl/Evidence`, capped at the 40 most
recent.

Nothing leaves your Mac unless you switch on **phone alerts**, which send the
alarm and up to three photos to your own private ntfy.sh link. That link's name
is 128 bits of randomness and is the access control — treat it like a password,
and rotate it from Settings if it leaks. ntfy deletes attachments after a few
hours, so the copies on your Mac are the durable ones.

See [PRIVACY.md](docs/PRIVACY.md).

## Known limitations, stated plainly

- **Repetitive backgrounds confuse motion detection.** Window blinds, tiled
  floors and brick make the camera unable to tell a passer-by from the laptop
  being moved. Use the sensitivity test in Settings at your actual table: if
  waving your hand moves the number, don't rely on motion detection there.
- **Quitting the app stops the alarm.** The Quit menu item is disabled while
  armed, but ⌘Q and Force Quit still work. Your audio settings are restored
  either way.
- **A thief can hold the power button.** Nothing in userspace prevents that.

## Install

**[Download Yowl 1.0.1](https://github.com/nejcar20/yowl/releases/download/v1.0.1/Yowl-1.0.1.dmg)**
— 1.2 MB, signed and notarised by Apple, so it opens with a double-click. Drag
it to Applications.

Or build it yourself; it takes about a minute and needs nothing but Xcode.

**You need:** macOS 14 or later, and Xcode 16 or later (or just the Command Line
Tools) for Swift 6.2+. Built and tested on Swift 6.3.3 / Xcode 26.6.

```bash
git clone https://github.com/nejcar20/yowl.git
cd yowl
swift test                  # 270 tests, ~30s the first time
./Scripts/make-bundle.sh    # produces build/Yowl.app
open build/Yowl.app
```

Move `build/Yowl.app` to `/Applications` if you want to keep it.

### First run

Yowl lives in the **menu bar** — no Dock icon and no window. Look for the shield
icon; everything is behind it.

- It asks for **camera access** the first time you switch on a camera feature
  (the motion trigger, or photographs). Nothing camera-related runs until you do.
- If you have no Apple Development certificate on your Mac, the build script
  signs the app ad-hoc and says so. Everything works, but macOS ties camera
  permission to the signature, so it will ask again after every rebuild.
- Nothing is armed until you press **Arm**.

### Requirements

macOS 14 or later. Universal binary — Apple Silicon and Intel. The lid trigger
needs the hinge angle sensor, which Intel Macs do not have; it stays hidden
there. Everything else works on both.

## Closing the lid all the way

Sleeps the Mac, and the siren stops with it. No application can prevent this:
Apple's `IOPMLib.h` states the system "may still sleep for lid close" whatever
assertion is held, and the `pmset disablesleep` override that once forced it is
not available on Apple Silicon.

What the app does instead is fire early — the lid trigger goes at 30° of travel,
roughly 80° before the lid shuts — so the siren, the screen lock, the
photographs and the push all happen in the window before sleep. On wake it
sounds again, which is the moment someone opens the lid.

## Why it is not on the Mac App Store

Locking the screen has no public API, so Yowl calls a private one — an automatic
rejection. A Store build would also lose the lid trigger (raw IOKit HID access is
not grantable under the sandbox) and the unlock-to-disarm behaviour (sandboxed
apps do not receive the screen-unlock notification), which would put the passcode
back. That is most of the reason the app is worth running, so it is distributed
directly instead: signed with a Developer ID certificate and notarised by Apple,
which is what lets the download open without a warning.

Releases are cut with `./Scripts/release.sh <version>` — build, sign, notarise
the app, staple it, package and sign the image, notarise and staple that too.

## Contributing

Bug reports are more useful than features right now. In particular:

- **Does motion detection work at your desk?** Use "Test sensitivity" in
  Settings, wave your hand, and tell me the number. Repetitive backgrounds
  (blinds, tiles, brick) are known to defeat it and I would like real data on
  how common that is.
- **Did the alarm ever fire when it should not have?** That is the failure that
  matters most.

The test suite is the contribution guide: `swift test` runs 241 tests, and
anything touching a trigger, a response, or the privacy-facing behaviour needs
one that fails when the change is reverted. Several bugs in this codebase
shipped behind tests that passed against broken code, so that bar is deliberate.

## License

MIT — see [LICENSE](LICENSE).

## Contact

jernejkocica@gmail.com — bug reports are better filed as
[issues](https://github.com/nejcar20/yowl/issues), but mail works.
