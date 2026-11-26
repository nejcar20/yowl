# Where things stand

_26 November 2026_

- **Mac:** 1.3.2 is released, signed and notarised: [GitHub
  releases](https://github.com/nejcar20/yowl/releases) and
  `brew install --cask nejcar20/tap/yowl`. Cut releases with
  `./Scripts/release.sh <version>`.
- **Windows:** live in the [Microsoft
  Store](https://apps.microsoft.com/detail/9NM387X4WVV2). The package comes from
  the `Windows` workflow. Store listing text is edited in Partner Center; the
  manifest description only seeds it.
- **Unreleased on `main`:** see [CHANGELOG.md](CHANGELOG.md).

## Open issues from the November 2026 review

Ordered by how much each one helps a thief or causes a missed alarm.

### Mac
1. **Lid shut during the grace period gives no alarm.** Sleep is held off only
   while firing (`AppModel.swift`, `updateLidSleepHold` and the sleep deferrer),
   and the grace timer stops while asleep. Fire at once when sleep begins
   during grace.
2. **`SudoersLidSleepSuppressor.isAvailable` runs `sudo pmset disablesleep 0`**
   on the main thread on every state change, before the siren starts, and
   drops any active hold. Replace it with `sudo -n -l …` run off the main thread
   and cached.
3. **Disarm leaves the built-in speakers at 100 %** when the default device was
   headphones. Save and restore the built-in device's volume and mute too.
4. **An armed Mac is unlocked**, and `com.apple.screenIsUnlocked` can be posted
   by any process. Option to lock on arm, and only accept an unlock after a lock
   has been seen.
5. **Crash or logout mid-alarm leaves state behind**: the forced volume is only
   in memory, and `applicationWillTerminate` does not release `disablesleep`.
6. The hold file is in shared `/tmp` (`/tmp/.yowl-hold-until`). Move it to the
   user's temp folder.
7. Camera loss while armed is silent: no frame-age watchdog.
8. `SleepDeferrer.releasePendingSleep()` has no caller.

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
