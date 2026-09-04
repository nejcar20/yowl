# Yowl — Privacy Policy

_Last updated: 3 September 2026_

**Yowl collects nothing about you and has no servers.** There is no
analytics, no crash reporting, no telemetry, and no account.

It sends data to exactly one place, only if you switch it on, and only to a
destination you control: your own phone.

## What stays on your Mac

| What | Where | Why |
|---|---|---|
| Your disarm passcode, if you set one | macOS Keychain, this device only | Stored as a salted PBKDF2-SHA256 hash. The passcode itself is never written down and cannot be recovered from what is stored. |
| Your settings | macOS user defaults | Which triggers and responses are switched on — including whether photographs and phone alerts are enabled — the grace period, and motion sensitivity. |
| Alarm photographs | `~/Library/Application Support/Yowl/Evidence` | Only if you switch on photographs. Capped at the 40 most recent; older ones are deleted automatically. |
| Your alert link | macOS Keychain, this device only | Only if you switch on phone alerts. |

## Phone alerts — the only thing that leaves your Mac

**Off by default.** Nothing is transmitted unless you switch on "Send an alert
to my phone".

When it is on, and the alarm fires, Yowl sends to **ntfy.sh**
(operated by Philipp Heckel, [ntfy.sh](https://ntfy.sh)):

- A short message saying which trigger fired and when.
- Up to three of the most recent alarm photographs — only if you have also
  switched on "Photograph whoever is there". With photographs off, alerts carry
  the message and nothing else.

**How your alerts are kept private.** Your alerts go to a private topic whose
name is 128 bits of randomness generated on your Mac. That name is the access
control: anyone who has the link can read your alerts and photographs, and
anyone who does not cannot find them. Treat the link like a password. You can
create a new one at any time from Settings, which immediately stops the old one
receiving anything further from your Mac.

**ntfy.sh is not storage.** Attachments are deleted after roughly three hours
and messages after twelve. The copies on your Mac are the durable ones.

**If you would rather not use a third party**, you can run your own ntfy server
— it is open source and self-hostable — or leave phone alerts off entirely and
use the photographs saved on your Mac.

## The camera

Used only if you turn on movement detection or alarm photographs. When either is
on and the alarm is armed, the green camera light is on; that is enforced by the
hardware and cannot be hidden.

Video is processed in memory to detect movement and then discarded. Still images
are saved only if you switched photographs on.

## What the app never does

- Does not use location services.
- Does not read your files, contacts, calendar, or browsing.
- Does not identify or profile you.
- Contains no third-party SDKs, trackers, or advertising.
- Sends nothing anywhere unless you switch on phone alerts.

## Your data rights

Nothing is collected about you, so there is no account to export or delete.
Everything is under your control:

- **Photographs:** open the folder from Settings and delete them.
- **Alert link:** create a new one, or switch alerts off, in Settings.
- **Passcode and link:** Keychain Access, search `com.jernejkocica.yowl`.
- **Settings:** stored in `~/Library/Preferences/com.jernejkocica.yowl.plist`. macOS does not remove this when an app is deleted; delete that file to clear it.

Under GDPR you may contact us about any of the above, though in practice we hold
nothing to act on.

## Contact

jernejkocica@gmail.com
