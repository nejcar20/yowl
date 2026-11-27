# Where things stand

_26 November 2026_

- **Mac:** 1.4.0 is released, signed and notarised: [GitHub
  releases](https://github.com/nejcar20/yowl/releases) and
  `brew install --cask nejcar20/tap/yowl`. Cut releases with
  `./Scripts/release.sh <version>`.
- **Windows:** live in the [Microsoft
  Store](https://apps.microsoft.com/detail/9NM387X4WVV2). The package comes from
  the `Windows` workflow. Store listing text is edited in Partner Center; the
  manifest description only seeds it.
- **Changes:** see [CHANGELOG.md](CHANGELOG.md).

## Open issues from the November 2026 review

Ordered by how much each one helps a thief or causes a missed alarm.

### Mac
1. **An armed Mac is unlocked**, and `com.apple.screenIsUnlocked` can be posted
   by any process. Option to lock on arm, and only accept an unlock after a lock
   has been seen.
2. **Crash mid-alarm leaves the forced volume behind**: the saved audio state is
   only in memory. Persist it and restore at launch.
3. The hold file is in shared `/tmp` (`/tmp/.yowl-hold-until`). Move it to the
   user's temp folder.
4. Camera loss while armed is silent: no frame-age watchdog.
5. `SleepDeferrer.releasePendingSleep()` has no caller.
6. The built-in speaker restore (`CoreAudioOutputControl.restore`) is verified
   by build only; check by hand with headphones connected: arm, fire, disarm,
   unplug the headphones.

### Windows
1. **No lid trigger**, and the lid action is only overridden while sounding, so
   shutting the lid while armed sleeps the laptop. Use
   `GUID_LIDSWITCH_STATE_CHANGE` and hold from arming.
2. **One throwing response stops the rest** (`AlarmEngine.FireResponsesAsync`),
   and there is no `Application.ThreadException` handler.
3. The power and sleep buttons, and Shut down on the lock screen, are not
   handled.
4. The lid action is not restored after a hard power-off unless Yowl is
   started again.
5. Per-app volume in the Volume Mixer can mute the siren.
6. Camera loss or a privacy shutter while armed is silent.
7. The camera reopen blocks the UI thread with no timeout (`WinRtCamera.cs`).

## If you change the photo or alert behaviour

`docs/PRIVACY.md` makes specific factual claims and ships inside the DMG.
Anything that changes what leaves the machine must change it in the same
commit.
