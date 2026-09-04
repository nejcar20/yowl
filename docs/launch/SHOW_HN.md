# Show HN draft

HN wants the interesting technical problem, not the pitch. Lead with what was
hard. Expect scrutiny of the privacy claim — that's good, it's the strongest
part.

Post between roughly 8–11am ET on a weekday. Be around to reply for the first
couple of hours or it dies.

---

**Title:** Show HN: A macOS alarm that tells the difference between your laptop
moving and people walking past it

**URL:** the GitHub repo

---

**First comment (post immediately after submitting):**

I built this because I kept leaving a laptop unattended in cafés. It's a
menu-bar alarm: arm it, and unplugging the charger, closing the lid, or picking
the machine up sets off a siren at forced maximum volume, locks the screen,
photographs whoever's there, and pushes it to your phone.

The interesting problem was camera-based motion detection. A café is the worst
case for it — people walk past constantly, and any frame-differencing approach
fires on all of them.

What works is asking whether a *single global transform* explains the change
between two frames. Vision's translational image registration gives you the best
alignment; you then warp by it and measure the residual. If the whole scene
shifted, the warp explains almost everything and the residual collapses. If
someone walked through a static scene, no translation explains it and the
residual stays high.

Two things I only learned by measuring:

1. **Registration alone is worse than useless here.** A person crossing a static
   background produces a spurious shift of ~170px on a 320px frame. It's the
   residual, not the shift, that does the discriminating — I have the numbers in
   the source comments.

2. **Periodic backgrounds defeat it entirely.** Window blinds, tiled floors,
   brick: shifting by one stripe width aligns as well as the true shift, so the
   residual can't separate the cases. I tried two guards and both were worse
   than the problem — one capped plausible shift and made the alarm silent on a
   *snatch* while still firing on a slow nudge. Both are reverted and the
   limitation is documented with its measurements. If someone knows the right
   answer here — feature-based registration with an inlier ratio, optical flow
   coherence — I'd like to hear it.

On privacy, since it asks for camera access: nothing leaves the machine unless
you turn on phone alerts, and that's the reason it's open source. There's one
HTTP client in the source and the signed app carries two entitlements. Both are
a one-line check, documented in the README, and I'd rather you verified than
believed me.

MIT, macOS 14+, no accounts or analytics. Tested on Apple Silicon only so far.
