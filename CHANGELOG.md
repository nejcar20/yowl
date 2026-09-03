# Changelog

## 1.0.0 — unreleased

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
