# Yowl for Windows

The Windows version of Yowl: the same theft alarm, in the notification area
instead of the menu bar. **Untested on real hardware so far.** Everything below
the "Windows pieces" line has only been compiled and run in CI, not on a laptop.

## Layout

| Project | What it is | Runs on |
|---|---|---|
| `src/Yowl.Core` | The engine, triggers, responses, motion detector, settings and alert logic. A port of `Sources/AlarmCore` and `AppModel`. | Any OS |
| `src/Yowl.Windows` | The tray app and every Windows API call | Windows 10 2004+ / 11, x64 and ARM64 |
| `tests/Yowl.Core.Tests` | 122 tests, mostly the Mac suite's scenarios | Any OS |

## Build

```
dotnet test tests/Yowl.Core.Tests
dotnet publish src/Yowl.Windows/Yowl.Windows.csproj -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true
```

Both work on macOS too (`EnableWindowsTargeting`); the exe just cannot run
there. CI (`.github/workflows/windows.yml`) builds on real Windows, runs the
tests and the self-test, and uploads `Yowl.exe` for x64 and ARM64 as an
artifact on every push that touches `windows/`.

`scripts/make-ico.sh` regenerates the icon from the Mac icon's drawing code.

## Testing on a Windows laptop

1. Get `Yowl.exe`: from the latest **Windows** run under the repo's Actions tab
   (artifact `Yowl-windows`; `win-x64` for Intel/AMD, `win-arm64` for
   Snapdragon), or build it as above.
2. It is unsigned, so SmartScreen will warn: **More info → Run anyway**.
3. In a terminal, run the self-test first. It changes nothing:
   ```
   Yowl.exe --self-test
   Yowl.exe --self-test --camera --siren
   ```
   The second form opens the camera for 3 s and plays the siren for 2 s at the
   current volume. The report is also saved to `%TEMP%\yowl-self-test.txt`.
4. Then the real walk, the same as the Mac acceptance test:
   - Start `Yowl.exe`. A shield appears in the notification area (it may be in
     the `^` overflow; drag it onto the taskbar).
   - Click it. With **Lock the screen** on, no passcode is needed; set one
     anyway under Settings to test that path.
   - Settings → turn on **Photograph whoever is there**, allow the camera.
   - Settings → **Send an alert to my phone** → scan the code → **Send test**.
   - Plug in the charger, **Arm**, pull the charger.
   - Expected: siren at full volume on the laptop speakers even with
     headphones in, Windows locks, photos in `%LOCALAPPDATA%\Yowl\Evidence`,
     a push with photos on the phone. Unlocking Windows disarms.
   - Try muting while it sounds: the volume should come back within a second.
   - Turn on **Laptop is moved**, use **Test sensitivity**: nudging the laptop
     should move the number, waving a hand should not.
   - Arm with the charger in and leave it until the screen turns off by
     itself, then pull the charger. It must still go off: on Modern Standby
     laptops this is the case most likely to differ from the Mac.
   - Turn on **Keep screaming with the lid closed**, arm, pull the charger,
     close the lid: it should keep sounding for the chosen time, and
     *Control Panel → Power Options → Choose what closing the lid does* should
     be back to your setting afterwards.

## Windows pieces

| Mac | Windows | File |
|---|---|---|
| Keychain | DPAPI-encrypted files in `%LOCALAPPDATA%\Yowl\Secrets` | `DpapiSecretStore.cs` |
| IOKit power source | `SystemInformation.PowerStatus` + `PowerModeChanged`, polled each second as backup | `SystemServices.cs` |
| `SACLockScreenImmediate` | `LockWorkStation` | `SystemServices.cs` |
| `com.apple.screenIsUnlocked` | `SessionSwitch` → `SessionUnlock` | `SystemServices.cs` |
| IOKit sleep assertion | `SetThreadExecutionState` plus a `PowerSetRequest`, for Modern Standby laptops | `SystemServices.cs` |
| CoreAudio: force built-in speakers | WASAPI: render straight to the endpoint whose form factor is *Speakers*, and hold its volume | `SpeakerAudio.cs` |
| AVAudioEngine siren | Same generated sweep, via NAudio | `SpeakerAudio.cs` |
| AVFoundation camera | `Windows.Media.Capture` frame reader | `WinRtCamera.cs` |
| Vision translational registration | Yowl's own coarse-to-fine block matching | `Yowl.Core/Vision/TranslationalRegistration.cs` |
| sudoers rule for `pmset disablesleep` | Lid close action set to *Do nothing* for the hold, restored by a watchdog `cmd.exe` and at next launch | `LidActionSuppressor.cs` |
| SMAppService login item | `HKCU\…\Run` | `SystemServices.cs` |
| Concealed pasteboard type | Clipboard flags that keep it out of clipboard history and cloud sync | `SystemServices.cs` |

## Differences from the Mac app

- **No lid-angle trigger.** Windows laptops expose no hinge sensor.
- **Headphones on a combined jack.** Where the speakers and headphone jack are
  one audio endpoint (common on Realtek laptops), plugging headphones in moves
  that endpoint to the jack, and the siren goes there. Separate endpoints (USB,
  Bluetooth, HDMI) cannot divert it.
- **Lid closed needs no password.** The Mac needs a one-time sudoers rule;
  Windows lets a user change their own lid action.
- **Quit from Task Manager** stops the alarm, as Force Quit does on the Mac.
  The tray's Quit is disabled while armed.

## Not done yet

- Code signing (SmartScreen warns until it is signed; Azure Trusted Signing is
  the cheapest route).
- An installer. For now it is a single exe; settings and photos live in
  `%LOCALAPPDATA%\Yowl`.
- A Windows section in the main README, the website, and the privacy policy.
