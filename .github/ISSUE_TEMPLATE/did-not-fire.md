---
name: It didn't go off when it should have
about: Something happened and the alarm stayed silent
labels: missed-alarm
---

**What did you do to trigger it?**

**Which triggers were switched on in Settings?**

**Did the menu bar say "Armed" beforehand?** If it showed a warning in orange,
please quote it — the app tries to tell you when a trigger cannot actually fire.

**Your Mac and macOS version:**

<!--
Known cases where this is expected:
- Arming while already on battery: the charger trigger needs the charger
  connected, and the app refuses to arm if nothing else is on.
- Lid trigger on an Intel Mac: there is no hinge sensor, so the option is hidden.
- Closing the lid fully: whether the alarm survives the machine sleeping is
  still an open question. See docs/ACCEPTANCE.md.
-->
