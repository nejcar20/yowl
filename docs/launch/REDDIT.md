# Reddit draft

Suggested subs: **r/macapps** (best fit), **r/swift** (the technical angle),
**r/opensource**, **r/apple** (stricter about self-promotion — read their rules
first, and do not post there the same day).

Post as a text post, not a link post. Reply to comments; that is most of the
value and most of the reason to post at all.

Post once, to one sub, and let it run for a day before trying another. Same-day
crossposting is the fastest way to get read as a marketer.

**Title options:**

1. I made a free, open-source alarm that screams when someone takes your MacBook
2. Yowl — an open-source Mac menu-bar alarm that keeps screaming after the thief
   closes the lid
3. I spent far too long making a MacBook scream with the lid shut. Here is the
   app.

(2 and 3 lead with the hard problem and will do better in r/swift and
r/macapps; 1 is the plainest and safest in r/apple.)

---

I kept leaving my laptop on café tables while I went to the counter, so I built
something to make that less stupid.

**What it does.** You arm it from the menu bar. If someone unplugs the charger,
closes the lid, or picks the machine up, it screams at full volume — it forces
the output to 100% and switches to the built-in speakers, so muting it or
plugging in headphones does not help. It also locks the screen, photographs
whoever is in front of it, and pushes that photo to your phone. Only unlocking
your Mac stops it.

**Up front, because it is the thing you would want told: it asks for your admin
password, once, and only if you turn on one specific feature.**

The feature is "keep making noise after the lid is closed". Closing the lid is
the actual theft gesture, and the naive version of this app goes silent about a
second later, which makes it useless for the case it was built for. macOS gives
userspace no way to stay awake through a clamshell close on battery — an
`IOPMAssertion` does not survive it, and `AppliesOnLidClose` is refused as user
and as root. The only lever that works is `pmset disablesleep`, which is
root-only. Amphetamine solves it the same way.

So the app writes exactly one sudoers rule, at
`/etc/sudoers.d/yowl-disablesleep`, allowing exactly two fixed commands and
nothing else:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

No wildcards, one user, absolute paths, validated with `visudo -c` before and
after it is written. Unticking the checkbox removes the file. The hold is capped
at one minute and enforced by a timestamp on disk, so a crash cannot leave your
Mac unable to sleep. If you do not want that on your machine, leave the feature
off and the rule never gets written — everything else works without it.

That is the most invasive thing in the app, and I would rather it come from me
than from someone reading the source in the thread.

**The bit I am actually pleased with.** Motion detection had one hard problem:
in a café people walk past constantly. Naive frame differencing is useless. So
it registers each frame pair and asks whether a single global transform explains
the change — if the whole scene shifted, the camera moved; if only part of it
changed, something moved in front of a still camera. There is a "Test
sensitivity" readout so you can check it at your own table: nudge the laptop and
the number jumps, wave your hand and it should not.

**Privacy, since it wants your camera.** Nothing leaves your Mac unless you turn
on phone alerts, which go through your own private ntfy.sh topic. There is
exactly one HTTP client in the source. That is the reason it is open source —
you should not take my word for it, and you do not have to:

```
grep -rn "URLSession\|NWConnection" Sources/
codesign -d --entitlements - /Applications/Yowl.app
```

**What it does badly**, because you will find out anyway:

- Repetitive backgrounds — window blinds, tiled floors, brick — defeat the
  motion detection. It genuinely cannot tell a passer-by from the laptop moving
  when the background repeats. The sensitivity test shows you this in seconds.
- ⌘Q still quits it. The Quit menu item is disabled while armed, but the
  keyboard shortcut is not, and shipping an app you cannot quit is its own kind
  of bad.
- A thief can hold the power button. Nothing in userspace prevents that.
- The build is universal, but I have only run it on one machine, an M5 Pro.
  Intel should work apart from the lid trigger (no hinge sensor), but nobody has
  tried it. Reports welcome.

**This is a deterrent, not recovery.** Turn on Find My and FileVault — those are
what actually protect a stolen Mac. This makes taking it loud and public, which
is a different job.

Free, MIT, no accounts, no analytics. macOS 14+. Signed and notarised, so it
opens with a double-click rather than a Gatekeeper fight.

https://dontstealmylaptop.com

Happy to answer anything about the lid problem or the detection approach —
those are the two parts that took real iterations.

---

## Notes before posting

- Read the target sub's self-promotion rules the same day you post. r/macapps
  wants the "I made this" disclosure in the post, which this has.
- Do not edit the post to add "EDIT: thanks for the gold". Do edit it to add
  corrections; Reddit rewards visible correction.
- The sudoers section is the highest-risk and highest-reward part of this post.
  Do not cut it to make the post shorter. If someone challenges it, the answer
  is the file itself — quote it.
- Expect "why not the App Store?" The honest answer: it needs a private
  screen-lock API, IOKit HID access for the hinge sensor, and the sandbox blocks
  the unlock notification it disarms on. It cannot be sandboxed, so it cannot
  ship there.
