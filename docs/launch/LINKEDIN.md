# LinkedIn draft

Post as a text post. If posting a carousel, order it: the photo of the two of
you first, then `docs/img/card.png`, then `state-firing.png`, then `phone.png`.
Link in the body. Tag Luka and ask them to comment rather than react. No
hashtags.

The first two lines are the whole game; LinkedIn folds everything after them
behind "see more".

---

Luka and I do our best work in bars.

Problem is, eventually you need the bathroom. So you either pack everything up
for four minutes, or you ask a stranger to watch it. A stranger who would do
absolutely nothing.

We had the idea there and then went looking, and of course it already existed.
A few of them. All paid, and all watching the same two things: the charger and
the lid.

So I built ours differently and gave it away.

Yowl screams at full volume when someone unplugs your Mac, closes the lid or
picks it up. Over mute, over headphones. Then it locks the screen and takes a
photo of whoever is standing there.

The camera is doing something unusual here. It is a sensor, not just a way to
get the photo. Every frame pair gets registered against the last, and the
question it asks is whether one single shift explains the whole picture. If
everything moved together, the camera moved, so the laptop moved. If only part
of it changed, somebody walked past a laptop that is sitting still. That is the
difference between an alarm you can use in a busy cafe and one you switch off
after ten minutes. I haven't found another Mac app that uses the camera this
way.

The lid nearly beat me though. Closing the lid is the actual theft gesture, but
macOS suspends more or less everything a second or two after it shuts, and on
battery that is not negotiable. A power assertion does not survive clamshell.
The documented flag for exactly this case, AppliesOnLidClose, gets refused even
when you ask as root. The only lever left is pmset disablesleep, which is root
only. So the app writes one narrowly scoped sudoers rule that allows two fixed
commands and nothing else, holds the Mac awake for a capped 60 seconds, and
deletes the rule the moment you switch the feature off. That single problem
took longer than every other feature put together.

Download it and try it on your own table. Free, MIT, open source. Suggestions
and bug reports very welcome, and a star on GitHub helps.

dontstealmylaptop.com

---

## Notes before posting

- No em dashes anywhere in the post, and none should creep back in. Same for
  semicolons and "not just X, but Y" phrasing. They are what makes a post read
  as written by a machine.
- The post says the idea was shared and the building was yours. If Luka did more
  than that, fix it before they read it.
- Do not upgrade "all paid" to "all expensive". They are $10–20; someone will
  quote the price back at you. Free beats cheap on its own.
- Keep the hedge in "I haven't found another". The lid technique itself is not
  novel — Amphetamine keeps a Mac awake the same way — so the claim that holds
  is about alarm apps, and about what you looked for. Do not let it drift into
  "nobody has ever done this".
- Naming the sudoers rule in the post is deliberate. It is the most invasive
  thing the app does, the source is public, and saying it first is the whole
  reason anyone should trust the rest.
- The image is generated: edit `card.html` and run `Scripts/make-launch-card.sh`.
