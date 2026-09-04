# GitHub setup

## Repository description (350 char limit)

> A menu-bar alarm that makes stealing your MacBook loud. Screams at full volume
> over mute and headphones, locks the screen, photographs whoever is there, and
> pushes it to your phone. Free, open source, and it can't phone home — there's
> one HTTP client in the source and you can go look at it.

## Topics

`macos` `swift` `swiftui` `security` `anti-theft` `menu-bar` `privacy`
`laptop-security` `computer-vision` `macos-app`

## Release notes for the v1.0.0 tag

```markdown
First public release.

**Arm it when you leave your laptop somewhere.** Unplug the charger, close the
lid, or pick the machine up, and it screams at maximum volume — over mute, over
headphones — locks the screen, photographs whoever is in front of it, and pushes
that to your phone. Only unlocking your Mac stops it.

### Triggers
- **Charger unplugged** — on by default
- **Laptop moved** — camera-based, and it tells the difference between the
  machine moving and people walking past it. Off by default
- **Lid closed part-way** — reads the hinge sensor, so it fires about 80° before
  the lid shuts. Needs the hinge sensor, so Apple Silicon only. Off by default

### Privacy
Nothing leaves your Mac unless you switch on phone alerts. There is one HTTP
client in the entire source and the signed app carries exactly two entitlements.
The README shows you the two commands to verify that yourself.

### Known limitations, up front
- Repetitive backgrounds — blinds, tiled floors, brick — defeat motion
  detection. The sensitivity test in Settings shows this in seconds at your desk
- ⌘Q still stops the alarm. The Quit menu item is disabled while armed; the
  keyboard shortcut is not
- Universal binary. Tested on Apple Silicon (M5 Pro, macOS 26.5); Intel should work apart from the
  lid trigger, but nobody has tried it — reports welcome

Requires macOS 14 or later.
```

## Suggested repo settings

- **Issues:** on. The templates ask the questions worth having answers to.
- **Discussions:** on, if you want "does this work on my Mac" traffic out of
  Issues.
- **Releases:** attach the notarised DMG to the v1.0.0 tag.
- **Pages:** Settings → Pages → Source: `main` branch, `/docs` folder. That
  serves `docs/index.html` for free at
  `https://<org>.github.io/<repo>/`.
