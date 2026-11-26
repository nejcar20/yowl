---
name: It didn't go off when it should have
about: Something happened and the alarm stayed silent
labels: missed-alarm
---

**What did you do to trigger it?**

**Which triggers were switched on in Settings?**

**Did Yowl say "Armed" beforehand** (menu bar on Mac, notification area on Windows)? If it showed a warning in orange,
please quote it — the app tries to tell you when a trigger cannot actually fire.

**Mac or Windows? Model and OS version:**

**Yowl version:**

<!--
Known cases where this is expected:
- Arming while already on battery: the charger trigger needs the charger
  connected, and the app refuses to arm if nothing else is on.
- Lid trigger on an Intel Mac: there is no hinge sensor, so the option is hidden.
- Lid trigger on Windows: there is no hinge sensor, so there is no lid trigger.
- Closing the lid fully on a Mac without "Keep screaming with the lid closed":
  the Mac sleeps and the siren stops until the lid is opened again.
-->
