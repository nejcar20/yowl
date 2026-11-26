# Security policy

Yowl asks for the camera, can send photographs off the machine, and on the Mac
can install one sudoers rule. A flaw in any of that matters, so please report
it privately.

## What counts

- A way to stop or silence the alarm without unlocking the machine, beyond the
  limitations the README already lists (quitting the app, holding the power
  button).
- Photographs or alerts reaching anyone other than the owner's own ntfy topic,
  or leaving the machine when phone alerts are off.
- The lid-closed helper (`/etc/sudoers.d/yowl-disablesleep`) granting more than
  its two `pmset` commands, or its install being open to tampering.
- Secrets (the ntfy topic, the passcode hash) readable or replaceable where
  they should not be.

## How to report

Use **[Report a vulnerability](https://github.com/nejcar20/yowl/security/advisories/new)**
on GitHub, or email jernejkocica@gmail.com. Include the platform, version, and
steps to reproduce. You should hear back within a week.

Only the latest release on each platform gets fixes.
