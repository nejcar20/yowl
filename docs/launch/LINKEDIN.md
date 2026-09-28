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

So we built ours differently and gave it away.

Yowl screams at full volume when someone unplugs your Mac, closes the lid or
picks it up. Over mute, over headphones. Then it locks the screen, photographs
whoever is standing there, and pushes that photo to your phone over ntfy. So
you find out while it is still happening, not when you get back to the table.

The camera is doing something unusual here. It is a sensor, not just a way to
get the photo. Each frame gets registered against the last, and the question is
whether one single shift explains the whole picture. Everything moved together
means the laptop moved. Only part of it changed means somebody walked past. We
haven't found another Mac app using the camera this way.

The lid nearly beat us. Closing the lid is the actual theft gesture, but a Mac
falls asleep a second or two after it shuts, and on battery it really means it.
We tried four of the obvious ways to keep it awake. None of them work once the
lid is shut. The fifth one does, and finding it took longer than every other
feature put together. It is also the one part of the app that asks your
permission first.

Download it and try it on your own table. Free, MIT, open source. Suggestions
and bug reports very welcome, and a star on GitHub helps.

dontstealmylaptop.com

---

## Notes before posting

- No em dashes anywhere in the post, and none should creep back in. Same for
  semicolons and "not just X, but Y" phrasing. They are what makes a post read
  as written by a machine.
- The post is written as "we" throughout, so it reads as joint work rather than
  as yours with Luka in the opening line. Make sure that is how Luka would
  describe it before you post, and tag them.
- Do not upgrade "all paid" to "all expensive". They are $10–20; someone will
  quote the price back at you. Free beats cheap on its own.
- Keep the hedge in "We haven't found another". The lid technique itself is not
  novel — Amphetamine keeps a Mac awake the same way — so the claim that holds
  is about alarm apps, and about what you looked for. Do not let it drift into
  "nobody has ever done this".
- This post keeps the lid work plain and does not name the sudoers rule. The
  Reddit draft does name it, in full, which is the right venue for it. The one
  line kept here, that it asks your permission first, is what stops the admin
  password arriving as a surprise in the comments. Do not cut that line.
- The image is generated: edit `card.html` and run `Scripts/make-launch-card.sh`.
