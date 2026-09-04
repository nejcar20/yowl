# LaptopAlarm

A menu-bar alarm that makes stealing your MacBook loud.

Free and open source (MIT). No accounts, no analytics, no servers.

Arm it when you leave your laptop on a café table. If someone unplugs the
charger, closes the lid, or picks the machine up, it screams at full volume —
over mute, over headphones — locks the screen, and photographs whoever is
in front of it. Only your passcode stops it.

## What it is not

This is a deterrent, not a recovery system. **Turn on Find My and FileVault** —
those are what actually recover or protect a stolen Mac. LaptopAlarm makes the
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
codesign -d --entitlements - /Applications/LaptopAlarm.app
#   com.apple.security.device.camera
#   com.apple.security.network.client
```

That client is used in exactly one place: sending an alert to the ntfy link you
chose, and only when you have switched phone alerts on. There is no other
network code, no analytics SDK, and no telemetry to find.

## Privacy

No accounts, no analytics, no servers of our own. Photographs are written to
`~/Library/Application Support/LaptopAlarm/Evidence`, capped at the 40 most
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

## Building

```bash
swift test              # 224 tests
./Scripts/make-bundle.sh
open build/LaptopAlarm.app
```

Releases: `./Scripts/release.sh 1.0.0` — builds, signs, notarises and packages
a DMG. Requires a Developer ID certificate and stored notarisation credentials;
the script tells you exactly what is missing.

## Requirements

macOS 14 or later. Universal binary. Apple Silicon for the lid trigger (Intel Macs have no hinge
angle sensor).

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
[issues](https://github.com/nejcar20/laptopalarm/issues), but mail works.
