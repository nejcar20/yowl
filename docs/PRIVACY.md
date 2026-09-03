# LaptopAlarm — Privacy Policy

_Last updated: 3 September 2026_

**LaptopAlarm does not collect, transmit, or receive any data whatsoever.**

The app has no servers, no analytics, no crash reporting, no telemetry, and no
network code of any kind. It cannot send anything anywhere, because there is
nothing in it that talks to a network.

## What the app stores, and where

Everything below stays on your Mac. None of it is transmitted.

| What | Where | Why |
|---|---|---|
| Your disarm passcode | macOS Keychain, on this device only | To stop the alarm. Stored as a salted PBKDF2-SHA256 hash — the passcode itself is never written down, and cannot be recovered from what is stored. |
| Your settings | macOS user defaults | Which triggers are on, the grace period, motion sensitivity. |
| Alarm photographs | `~/Library/Application Support/LaptopAlarm/Evidence` | Only if you switch on "Photograph whoever is there". Capped at the 40 most recent; older ones are deleted automatically. |

## The camera

The camera is used only if you turn on movement detection or alarm
photographs. When either is on and the alarm is armed, the green camera light
is on — that is enforced by the hardware and cannot be hidden.

Video is processed in memory to detect movement and is discarded. If you have
switched on alarm photographs, still images are written to the folder above and
stay there until you delete them or they age out of the 40 most recent.

**No image ever leaves your Mac.** There is no upload, no cloud, no sync.

## What the app does not do

- Does not use location services.
- Does not read your files, contacts, calendar, or browsing.
- Does not identify you, profile you, or build any record of your behaviour.
- Does not contain third-party code, SDKs, trackers, or advertising.

## Your data rights

Because no personal data is collected or transmitted, there is nothing for us
to access, export, correct, or delete on your behalf. Everything the app stores
is on your own machine and under your control:

- **Photographs:** open the folder from Settings and delete them.
- **Passcode:** Keychain Access, search for `com.jernejkocica.laptopalarm`.
- **Settings:** removed when you delete the app.

## Contact

jernejkocica@gmail.com

---

*This policy describes the app's behaviour as shipped. If a future version adds
anything that transmits data — for example sending an alarm photo to your phone
— this policy will be updated in the same release, and the app will ask before
sending anything.*
