# Acceptance — end-to-end verification

_4 September 2026 — reported by Jernej Jan Kocica on a MacBook Pro (Mac17,9,
Apple M5 Pro, macOS 26.5)._

## Result

The full chain was exercised on real hardware and worked: arming, the trigger
firing, the siren, the screen lock, photographs written to disk, and the push to
a phone with photographs attached.

This closes the gap that stood through the whole build. Every component had
tests and every wiring path had a review, but until this point no human had
watched the sequence happen. "It shipped and did not fire" was the one failure
no amount of unit testing could have ruled out.

## What this does and does not establish

**Established:** the components compose. Arm → trigger → siren → lock →
photograph → push works as a sequence on a real machine, with a real camera, a
real speaker and a real phone.

**Not established by this run:**

- **Behaviour with the lid closed.** The clamshell probe
  (`spike/clamshell/main.swift`) has never been run. Whether the alarm survives
  the lid being shut is therefore still unknown, and no claim should be made
  about lid-closed protection until it is.
- **Behaviour in a café.** Motion detection is known to be defeated by
  repetitive backgrounds — blinds, tiled floors, brick. A desk that works says
  nothing about a room that does not. The sensitivity readout in Settings is the
  way to check any given table.
- **Alert delivery on a failing network.** There is no retry, and the likeliest
  theft — someone carrying the machine out of Wi-Fi range — is also the likeliest
  send failure.

## Standing limitations

Unchanged by this run, and documented in the README and CHANGELOG:

- ⌘Q and Force Quit stop the alarm. The Quit menu item is disabled while armed;
  the keyboard path is not. Audio settings are restored either way.
- A thief can hold the power button.
