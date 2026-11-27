# Contributing to Yowl

Thanks for helping. Bug reports are worth more than features right now.

## Reports that help most

- **Does motion detection work at your desk?** Open Settings → Test
  sensitivity, wave your hand in front of the camera without touching the
  laptop, and tell me what the number does. Repetitive backgrounds (blinds,
  tiles, brick) are known to defeat it, and real data on how common that is
  helps.
- **Did the alarm go off when it should not have?** That is the failure that
  matters most. Use the "It went off when it shouldn't have" issue template.
- **Did it stay silent when it should have gone off?** Use "It didn't go off".
- **Does it work on your laptop?** Intel Macs, older macOS and every Windows
  laptop are under-tested. Use "Report that it works".

A way to defeat the alarm, or a privacy problem, is a security report: follow
[SECURITY.md](SECURITY.md) and do not open a public issue.

## Building

**Mac:** macOS 14+, Xcode 16+ (or the Command Line Tools), Swift 6.2+.

```bash
swift test                  # the whole suite, ~30s the first time
./Scripts/make-bundle.sh    # produces build/Yowl.app
```

**Windows:** .NET 10 SDK on Windows 10 (2004+) or 11. Build steps, a testing
walk and the packaging script are in [windows/README.md](windows/README.md).

```powershell
dotnet test windows/tests/Yowl.Core.Tests
```

## Pull requests

- **Tests are the contribution guide.** Anything touching a trigger, a
  response, or what leaves the machine needs a test that fails when the change
  is reverted. Several bugs here shipped behind tests that passed against
  broken code, so that bar is deliberate. Say in the PR which test it is.
- **Privacy claims are kept true.** `docs/PRIVACY.md` makes specific factual
  claims and ships inside the app. A change to what is photographed, stored or
  sent updates it in the same PR.
- **User-visible changes** get a line under the top section of
  [CHANGELOG.md](CHANGELOG.md).
- **Mac and Windows behave the same** unless a platform cannot. If your change
  is for one, say whether the other needs it too.
- Keep PRs to one change. CI builds and tests both platforms on every PR.

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).
