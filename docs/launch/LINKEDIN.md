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

Yowl screams at full volume when someone unplugs your Mac, closes the lid or
picks it up. Over mute, over headphones. Then it locks the screen, photographs
whoever is standing there, and sends that photo to your phone, so you find out
while it is still happening.

The video is Luka taking his own laptop off our stand at a trade fair.

The camera is the unusual bit. It is a sensor here, not just a way to get the
photo, so it can tell the laptop moving from somebody walking past. We haven't
found another Mac app using it that way.

The lid nearly beat us. A Mac falls asleep a second or two after it shuts, and
on battery it really means it. We tried four of the obvious ways to keep it
awake. None work. The fifth does, and finding it took longer than every other
feature put together. It is also the only part that asks your permission.

Try it on your own table. Free, MIT, open source. Suggestions and bug reports
very welcome, and a star on GitHub helps.

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
  line kept here, that it asks your permission, is what stops the admin password
  arriving as a surprise in the comments. Do not cut that line.
- The image is generated: edit `card.html` and run `Scripts/make-launch-card.sh`.
- Media order: the video first (it autoplays in feed and shows the whole thing
  in ten seconds), then the photo of the two of you, then the ntfy screenshot,
  then `docs/img/card.png`.
- **The raw ntfy screenshot leaks the topic name.** That string is the access
  control: anyone who reads it can subscribe to the alert feed and see every
  photo the app sends. Post only a copy with it covered by a solid bar, never a
  blur, and regenerate the topic in the app afterwards.
