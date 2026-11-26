# Changelog

Full notes for each release are on the
[releases page](https://github.com/nejcar20/yowl/releases).

## Unreleased

### Changed
- **Everything is on by default**: the charger, movement and lid triggers,
  siren, screen lock and photographs. Phone alerts stay off, since they send
  data out.
- iPhones pair by typing the topic, since iOS cannot open the ntfy app from a
  scanned code. Android keeps the QR code.
- **Yowl for Windows**, in the
  [Microsoft Store](https://apps.microsoft.com/detail/9NM387X4WVV2).

### Fixed
- **Phone alerts attach only photographs from that alarm.** If the camera gave
  no frame, an alert used to attach the newest photos on disk, which could be
  an earlier alarm's. Mac and Windows.
- **The lid-closed helper install can no longer be hijacked.** The sudoers rule
  was staged in the user's temp folder and installed from there as root after
  the password prompt, so a process running as the user could swap the file.
  The root command now writes the rule text itself.
- The Windows Store description no longer claims closing the lid triggers the
  alarm. On Windows it does not; it only keeps an alarm that is already
  sounding going.
- The privacy policy no longer suggests you can use your own ntfy server.

## 1.3.2 — 2026-10-08
- Installing the lid-closed helper says why it failed instead of only "not
  installed" (#1), and checks only Yowl's own sudoers file afterwards.

## 1.3.1 — 2026-09-20
- Clicking the word **Settings** toggles the settings; VoiceOver hints added.

## 1.3.0 — 2026-09-20
- Choose how long the siren keeps the Mac awake with the lid shut: 30 s, 1, 2
  or 5 minutes.

## 1.2.0 — 2026-09-20
- **Keep screaming with the lid closed** works, through a single sudoers rule
  for `pmset disablesleep`. Off by default.

## 1.1.3 — 2026-09-20
- Fixes a crash on Arm introduced in 1.1.0.

## 1.1.0 — 2026-09-20
- First attempt at keeping the siren going with the lid closed. Superseded by
  1.1.3 and 1.2.0.

## 1.0.2 – 1.0.4 — 2026-09-20
- Theft is noticed about ten times faster.
- 1.0.3 and 1.0.4 claimed the siren keeps sounding with the lid shut; it did
  not, as their release notes now say.

## 1.0.1 — 2026-09-20
- The alarm sounds again when the Mac wakes, and stays silent after a normal
  disarm.

## 1.0.0 — 2026-09-10

First public release.

### Triggers
- Charger unplugged (on by default; requires the charger connected to arm).
- Laptop moved, using the camera. Distinguishes the machine moving from people
  walking past it, with an adjustable sensitivity and a live readout for
  calibrating at your own desk. Off by default.
- Lid closed part-way, read from the hinge sensor so it fires roughly 80° before
  the lid shuts. Off by default. Apple Silicon only.

### When it fires
- Siren at forced maximum volume from the built-in speakers, overriding mute and
  any connected headphones, restoring your audio settings on disarm.
- Screen lock.
- Photographs of whoever is in front of the machine, including the ten seconds
  before the alarm. Saved locally, capped at the 40 most recent. Off by default.
- A push to your phone through your own private ntfy link, with photographs
  attached only when photographs are switched on. Off by default.

### Deliberately not included
- **Wi-Fi trigger.** Two implementations were built and both were worse than
  nothing: one could not tell a disconnection from an API error, the other went
  permanently dead after a single disarm and fired on stationary laptops.
- **Location capture.** Would need a third permission prompt for little gain
  over Find My.
- **Retry when an alert fails to send.** Known gap; the likeliest theft is also
  the likeliest failure.

### Known limitations
- Repetitive backgrounds (blinds, tiled floors, brick) defeat motion detection —
  it cannot tell a passer-by from the laptop being moved there. The sensitivity
  test in Settings shows this in seconds.
- ⌘Q and Force Quit still stop the alarm. The Quit menu item is disabled while
  armed; the keyboard path is not. Your audio settings are restored either way.
- A thief can hold the power button.
