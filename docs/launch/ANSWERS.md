# Answers for the comments

Prepared replies for the questions the launch posts will attract. Written to be
pasted and edited, not read out. Keep the hedges.

---

## "What was the magic with the lid?"

### Short answer, for a casual comment

macOS will not let an app keep a Mac awake once the lid is shut. Not with the
normal APIs, and on battery it is strict about it. The only thing that actually
works is a system setting that needs root, so Yowl asks for your password once,
installs a rule that lets it flip that one setting and nothing else, and deletes
the rule when you turn the feature off. Amphetamine keeps a Mac awake the same
way, so the technique is not ours, just unusual in an alarm.

### Longer answer, for somebody who writes Mac software

Four things were tried before the one that worked, and each failed differently.

**Power assertions.** `IOPMAssertionCreateWithName` with the no-idle-sleep
assertions is the obvious first move, and it is the wrong tool: those prevent
*idle* sleep. Clamshell sleep is a different path and goes straight past them.

**Deferring the sleep notification.** `IORegisterForSystemPower` lets you hold
off a pending sleep for about thirty seconds. That buys time, it does not keep
audio running, and the siren is the entire point. It bought silence with a
delay on it.

**`AppliesOnLidClose`.** There is a documented flag for exactly this case. It is
refused as a normal user, and it is still refused as root. `IOPMSetSystemPowerSetting`,
which is the other way at it, is not in the public SDK.

**A privileged helper.** An `SMAppService` daemon with an XPC connection, which
is the Apple-sanctioned way to do privileged work. It registered cleanly,
reported itself `enabled`, was signed and notarised, and launchd never started
it, so every call failed. `unregister()` did not take either. That one got
deleted rather than left in the bundle as dead privileged machinery.

**What works** is `pmset -a disablesleep 1`, which is root only. So the app
writes one sudoers rule at `/etc/sudoers.d/yowl-disablesleep` granting the
current user exactly two commands, absolute paths, fixed arguments, no
wildcards:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

`visudo -c` validates it before it goes near `/etc` and again after it lands,
because a malformed sudoers file can lock you out of `sudo` entirely.

### Three details that are worth more than the rest

These are the parts that took the actual time.

- **`pmset` exits 0 for settings it ignores.** Trusting the exit status means
  shipping a feature that reports success on hardware where it silently does
  nothing. `setSleepDisabled` writes the value and then reads the flag back,
  and only returns true if it actually changed. That is what makes it work on
  Macs other than the one it was written on.
- **The install has to be async.** Running `osascript ... with administrator
  privileges` synchronously on the main actor means the admin dialog has
  nowhere to draw. The UI is blocked waiting for the prompt it needs to
  present, so no prompt appears and the install quietly does not happen. That
  looked like a permissions bug for a while.
- **A crashed app must not leave a Mac that cannot sleep.** A laptop held awake,
  shut in a bag with the camera running, is a thermal problem rather than an
  inconvenience. So the hold is a timestamp in a file plus a detached shell that
  outlives the app: it polls the file, and the moment it is stale or gone it
  runs `disablesleep 0` itself. Force quit the app, pull the battery, carry it
  off mid alarm, and the Mac still gets to sleep. The dangerous state is the one
  that expires on its own.

Holds are capped. The setting offers 30 seconds, 1 minute, 2 minutes or 5
minutes, and anything hand edited into the preferences gets clamped back into
that range. A siren is meant to be unbearable to stand next to, not to run for
an hour.

---

## "Why not the App Store?"

It cannot be sandboxed. It needs a private API to lock the screen immediately,
IOKit HID access for the hinge angle sensor, and the sandbox blocks the
screen-unlock notification it disarms on. Any one of those is disqualifying.

## "What about Find My?"

Find My is what recovers a stolen Mac and you should have it on. This is a
different job: making the theft loud, public and photographed at the moment it
happens, in a room with other people in it. It is a deterrent, not recovery,
and the README says so in those words.

## "Does it phone home?"

No. There is one HTTP client in the whole source and it only runs if you turn on
phone alerts, which go to your own private ntfy topic. Two commands check it:

```
grep -rn "URLSession\|NWConnection" Sources/
codesign -d --entitlements - /Applications/Yowl.app
```

## "Isn't a sudoers rule dangerous?"

It is the most invasive thing the app does, which is why it is named in the
Reddit post rather than buried. What makes it narrow: two absolute paths, fixed
arguments, no wildcards, one user, and `pmset disablesleep` is not a lever that
does anything except let a Mac sleep or not. Unticking the setting removes the
file. If you would rather not have it, leave that one feature off and everything
else still works.

## "Does the camera detection actually work?"

Sometimes not, and the app tells you so. Repetitive backgrounds defeat it:
window blinds, tiled floors, brick. With a repeating pattern it genuinely cannot
tell a passer-by from the laptop moving. There is a sensitivity readout in the
settings so you can test it at your own table in about ten seconds, which is the
honest way to ship something with that failure mode.
