# Where things stand

_3 September 2026_

Everything is merged to `main`. 233 tests, clean build, app built at
`build/LaptopAlarm.app`.

## What works

| | |
|---|---|
| Charger unplugged → alarm | ✅ |
| Laptop moved (camera) → alarm | ✅ verified on real hardware |
| Lid closed part-way → alarm | ✅ sensor verified, threshold 30° |
| Siren at forced max volume, over mute and headphones | ✅ |
| Screen lock | ✅ |
| Photographs, incl. the 10s *before* the alarm | ✅ |
| Push to phone with photos | ✅ verified against live ntfy |
| Settings, all opt-in, frozen while armed | ✅ |
| Icon, privacy policy, README, release pipeline | ✅ |

## Two things block shipping, both yours

1. **Developer ID certificate.** Xcode → Settings → Accounts → Manage
   Certificates → **+** → *Developer ID Application*. The "Apple Development"
   cert we build with cannot be notarised, so downloaders would see
   "the developer cannot be verified".

2. **Notarisation credentials.** App-specific password from appleid.apple.com,
   then:
   ```
   xcrun notarytool store-credentials laptopalarm \
     --apple-id <your-apple-id> --team-id U2C2MA4YJZ --password <password>
   ```

Then `./Scripts/release.sh 1.0.0` does the rest and hands you a notarised DMG.
It checks both prerequisites first and tells you exactly what is missing.

## What nobody has verified

**The whole chain has never been seen firing together on real hardware.** Each
part works; the wiring between them is verified by reading and by tests, not by
a human watching it happen. Before announcing anything:

1. Settings → turn **Charger unplugged** back on (it is currently off in your
   stored preferences from when you were trying the toggles)
2. Turn on **Photograph whoever is there**, grant the camera prompt
3. Turn on **Send an alert to my phone** → **Copy my link** → open on your
   phone → **Send test**
4. Plug in the charger, **Arm**, pull the charger

That should give you: siren, locked screen, photos on disk, push with images.

## Known limitations, all documented in the README

- Repetitive backgrounds (blinds, tiles, brick) defeat motion detection — it
  fires on passers-by there. The sensitivity test in Settings shows this in
  seconds at your actual table.
- ⌘Q and Force Quit still stop the alarm. The Quit menu item is disabled while
  armed; the keyboard path is not. Audio is restored either way.
- No location capture. It would need a third permission prompt and another
  privacy-policy rewrite, so it was left for you to decide.
- No Wi-Fi trigger. Two implementations were built and both were worse than
  nothing — one fired on stationary laptops, the other went dead after a single
  disarm. Cut deliberately.
- No retry if an alert fails to send.
- The app target has no test target, so `AppModel` wiring is verified by reading.
  That gap is behind most of what the reviews found.

## If you change the photo or alert behaviour

`docs/PRIVACY.md` makes specific factual claims and ships inside the DMG. It is
currently accurate. Anything that changes what leaves the Mac must change it in
the same commit.
