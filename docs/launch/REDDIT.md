# Reddit draft

Suggested subs: **r/macapps** (best fit), **r/swift** (for the technical angle),
**r/apple** (stricter about self-promotion — read their rules first).

Post as a text post, not a link. Reply to comments; that's most of the value.

---

**Title:** I made a free, open-source alarm that screams when someone takes your MacBook

---

I kept leaving my laptop on café tables while I went to the counter, so I built
something to make that less stupid.

**What it does.** You arm it from the menu bar. If someone unplugs the charger,
closes the lid, or picks the machine up, it screams at full volume — it forces
your volume to 100% and switches to the built-in speakers, so muting it or
plugging in headphones doesn't help. It also locks the screen, photographs
whoever is in front of it, and pushes that photo to your phone. Only your
passcode stops it.

**The bit I'm actually pleased with.** Motion detection had one hard problem: in
a café, people walk past constantly. Naive frame differencing is useless. So it
registers each frame pair and asks whether a single global transform explains
the change — if the whole scene shifted, the camera moved; if only part of it
changed, something moved in front of a still camera. There's a "Test
sensitivity" readout so you can check it at your own table: nudge the laptop and
the number jumps, wave your hand and it shouldn't.

**Privacy, since it wants your camera.** Nothing leaves your Mac unless you turn
on phone alerts. There is exactly one HTTP client in the source. That's the
reason it's open source — you shouldn't take my word for it, and you don't have
to:

```
grep -rn "URLSession\|NWConnection" Sources/
codesign -d --entitlements - /Applications/Yowl.app
```

**What it does badly**, because you'll find out anyway:

- Repetitive backgrounds — window blinds, tiled floors, brick — defeat the
  motion detection. It genuinely cannot tell a passer-by from the laptop moving
  when the background repeats. The sensitivity test shows you this in seconds.
- ⌘Q still quits it. The Quit menu item is disabled while armed but the keyboard
  shortcut isn't, and making an app you can't quit is its own kind of bad.
- The build is universal, but I've only run it on one machine, an M5 Pro. Intel should work except the lid
  trigger (no hinge sensor), but nobody has tried.

**This is a deterrent, not recovery.** Turn on Find My and FileVault — those are
what actually protect a stolen Mac. This just makes taking it loud and public.

Free, MIT, no accounts, no analytics. macOS 14+.

[link]

Happy to answer anything about the detection approach — that's the part that
took the most iterations to get right.
