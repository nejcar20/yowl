# LinkedIn draft

Post as a text post with the media attached. Tag Luka and ask them to comment
rather than react. No hashtags.

Keep the link in the body. It is a bare domain rather than a full URL, the
attached video is already the preview, and "link in comments" costs a tap at
the exact moment somebody has decided to look. Drop it into the first comment
as well, which is free and catches anyone who reads the comments first.

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

The video is Luka stealing his own laptop and getting caught in the act. Not a
natural criminal.

The clever part is that it watches through the camera. Not to take the picture,
but to tell your laptop being picked up from somebody just walking past it in a
busy room. We haven't found another Mac app that does that.

Try it out on your own Mac. Free, MIT, open source. Suggestions and bug reports
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
- This post does not mention the lid feature at all, so it does not need to
  mention the admin password either. The Reddit draft covers both in full, which
  is the right venue. If a commenter asks here, the answer is in ANSWERS.md.
- The image is generated: edit `card.html` and run `Scripts/make-launch-card.sh`.
- Media order: the video first (it autoplays in feed and shows the whole thing
  in ten seconds), then the photo of the two of you, then the ntfy screenshot,
  then `docs/img/card.png`.
- **The raw ntfy screenshot leaks the topic name.** That string is the access
  control: anyone who reads it can subscribe to the alert feed and see every
  photo the app sends. Post only a copy with it covered by a solid bar, never a
  blur, and regenerate the topic in the app afterwards.
