# Reddit draft

Suggested subs: **r/macapps** (best fit), **r/swift**, **r/opensource**.
r/apple is stricter — read their rules, and not the same day.

Text post, not a link post. Post to one sub and let it run a day; same-day
crossposting reads as marketing. The comments are most of the value.

**Title options:**

1. I made a free, open-source alarm that screams when someone takes your MacBook
2. An open-source Mac alarm that keeps screaming after the thief closes the lid

---

I kept leaving my laptop on café tables while I went to the counter, so I built
something to make that less stupid.

**What it does.** Arm it from the menu bar. If someone unplugs the charger,
closes the lid, or picks the machine up, it forces the volume to 100% and
switches to the built-in speakers — so muting it or plugging in headphones does
not help. It locks the screen, photographs whoever is in front of it, and pushes
that photo to your phone. Only unlocking your Mac stops it.

**Up front: it asks for your admin password once, and only for one feature.**

That feature is staying loud after the lid closes. macOS gives userspace no way
to survive a clamshell close on battery — an `IOPMAssertion` does not make it,
and `AppliesOnLidClose` is refused even as root. The only lever that works is
`pmset disablesleep`, which is root-only. Amphetamine does the same thing.

So it writes one sudoers rule at `/etc/sudoers.d/yowl-disablesleep` allowing two
fixed commands and nothing else:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

No wildcards, one user, absolute paths, `visudo -c` validated. Unticking the box
deletes it. The hold is capped at 60 seconds and enforced by a timestamp on
disk, so a crash cannot leave your Mac unable to sleep. Leave the feature off and
the rule is never written — everything else still works.

**"Doesn't this already exist?"** Yes. Unplug Alarm, SlapMac, Clyde, MacGuard. I
found them after having the idea, which is the normal order of these things.
Most are cheap rather than expensive, so that is not my pitch — free, MIT and
auditable is.

The actual difference is the camera, and not for the photo; several of them
photograph the thief too. Yowl can use the camera as the *sensor*. In a café
people walk past constantly, so frame differencing is useless. It registers each
frame pair and asks whether one global transform explains the change: whole
scene shifted means the camera moved, part of it changed means something moved
in front of a still camera. There is a sensitivity readout so you can test it at
your own table.

Everything else I found triggers on the charger, the lid, or the accelerometer.
If there is another one doing camera ego-motion, I would genuinely like to see
it — I looked and could not find one.

**What it does badly:**

- Repetitive backgrounds (blinds, tiled floors, brick) defeat the motion
  detection outright.
- ⌘Q still quits it. The menu item is disabled while armed; the shortcut is not.
- A thief can hold the power button. Nothing in userspace stops that.
- Universal build, but only tested on one M5 Pro. Intel should work except the
  lid trigger. Reports welcome.

**This is a deterrent, not recovery.** Find My and FileVault are what actually
protect a stolen Mac. This just makes taking it loud.

Free, MIT, no accounts, no analytics. macOS 14+, signed and notarised.
Stars and bug reports both welcome — I have only tested it on my own Mac.

https://dontstealmylaptop.com

Happy to answer anything about the lid problem or the detection.

---

## Notes before posting

- Do not cut the sudoers section to shorten it further. It is the most invasive
  thing the app does and the source is public; a thread that finds it on its own
  becomes a thread about trustworthiness instead of about the app.
- Expect "why not the App Store?" — it needs a private screen-lock API, IOKit
  HID for the hinge sensor, and the sandbox blocks the unlock notification it
  disarms on. It cannot be sandboxed, so it cannot ship there.
