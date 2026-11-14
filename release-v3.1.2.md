# PhaseRings v3.1.2 — App Store submission notes

Working notes for the v3.1.2 bug-fix update (prepared 2026-11-14, on top of
v3.1.1 which is in review).

## What's in v3.1.2

**AUv3 plugin**
- **Host automation now works.** The render block only handled MIDI events,
  so parameter automation from Logic, GarageBand, Cubasis etc. (delivered as
  `AURenderEventParameter` / `ParameterRamp`) was silently ignored. Automation
  now applies on the render thread (ramps jump to their end value). `sound`
  automation switches synth on the render thread too: all three Heavy
  contexts are now built in `allocateRenderResources` so no construction
  happens there.
- **Synth switches keep the levels.** Each synth is its own Heavy context, so
  after a `sound` change the new context never heard master/reverb/effects/sing
  levels. Every level is now re-sent on a switch (both main-thread and
  automation paths).
- **No repeated `selectsound`.** `sound` is only applied when it changes
  (PRAudioUnitStore rewrites every parameter on each settings edit; a repeated
  `selectsound` is the #34 grind).
- **Sustain-pedal sing voice works with the plugin UI closed** (and in
  offline bounces). The CC64 sing gate moved from the UI (drained only while
  the view was on screen) to the render thread; the UI now just lights rings.
  Stale UI events queued while the window was closed are discarded on reopen
  instead of replayed.

**Standalone app**
- **MIDI-in no longer drops chords.** Packets carrying several messages or
  running status are parsed byte by byte (previously only exactly-3-byte
  packets were read). Covered by `MetatoneMidiInputTests`.
- **Audio recovers from a media-services reset** (engine rebuilt instead of
  silent until relaunch), and the audio session is reactivated explicitly
  when audio restarts after an interruption.
- **Settings.app defaults match the app** (`sound` = Singing Bowls,
  `composition` = Study in Bowls) — previously a fresh install showed
  "Phase Synthesis" in Settings while the app played Singing Bowls.

## App Store metadata — What's New

```
Fixes for the AUv3 plugin: host automation of PhaseRings parameters now works, and the sustain-pedal sing voice plays even when the plugin window is closed. The app now plays every note of chords sent over MIDI, and recovers its audio if iOS restarts its audio system.
```

## Pre-submission device checklist

- [ ] Logic / GarageBand: automate Sing Level, Reverb, Master — audible; automate Sound — switches synth with levels intact
- [ ] AUM: MIDI-learn a parameter still works; plugin plays cleanly at 44.1 and 48 kHz
- [ ] AUv3 with UI closed: hold sustain + play a note → sing voice sounds; release → stops
- [ ] Reopen plugin UI after playing with it closed → no burst of ring flashes
- [ ] Standalone: USB/network MIDI keyboard chords play every note; sustain pedal sing works
- [ ] Standalone: phone call / Siri interruption → audio resumes afterwards
- [ ] Fresh install: Settings.app shows Singing Bowls / Study in Bowls
- [ ] Settings About shows "Version 3.1.2 (n)"
