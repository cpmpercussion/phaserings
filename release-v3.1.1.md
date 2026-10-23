# PhaseRings v3.1.1 — App Store submission notes

Working notes for the v3.1.1 App Store Connect submission (bug-fix update).
v3.1 prepared 2026-06-12; v3.1.1 prepared 2026-10-23.

## What's in v3.1.1

- **AUv3 click/glitch fix (#45)** — the plugin produced continuous clicks in
  AUM and Logic Pro whenever the host ran at 44.1 kHz on 48 kHz iPad hardware
  (the default in both). Those hosts deliver alternating 235/236-frame render
  cycles; Heavy's generated DSP only renders whole 4-sample vectors and left
  the tail of every block unwritten. The shared render callback now renders
  through an aligned scratch block and carries the surplus samples forward,
  so any frame count renders cleanly. Also tolerates mono host buffer lists.
  Reported by a player by email.
- **UIScene life cycle adoption** — required to launch when built with the
  iOS 27 SDK (Xcode 27). Window creation and the foreground/background audio
  handling moved from `AppDelegate` to a new `SceneDelegate`. No visible
  change.

No new features, no UI changes, no permission or entitlement changes from v3.1.

## App Store metadata

Only **What's New** changes from `appstore-metadata-v3.1.md`:

```
Fixes clicks and glitches when PhaseRings runs as an AUv3 plugin in AUM or Logic Pro at 44.1 kHz. Thanks to the player who reported it.
```

## Pre-submission device checklist

- [ ] AUM at 44.1 kHz (its default) and at 48 kHz: plugin plays cleanly
- [ ] Logic Pro for iPad, 44.1 kHz project: plugin plays cleanly
- [ ] Standalone app: launches, plays, settings and ensemble features work;
      audio stops on resign-active and resumes on becoming active
- [ ] Settings About section shows "Version 3.1.1 (n)" with the CI build number
