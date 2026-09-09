# Phase 2 Windows Audio Plan (issue 8)

Windows half of the audio path on top of the merged Phase 1 transport.
Manual START/STOP drives real microphone audio: WASAPI shared-mode capture,
48 kHz mono s16le, 960-sample / 20 ms frames at 50 fps.

## Task status

- [x] Task 1: PcmNormalizer (float to s16le, stereo to mono mix/left/right,
      conditional resample, clipping) with spec 10.1 golden tests.
      Evidence: PcmNormalizerTests, 11 tests green.
- [x] Task 2: DeviceManager (pinned endpoint ID, presence check,
      hot-unplug/replug, STATUS emission, mic-loss NACK before the session
      check per server.py). Evidence: DeviceManagerTests, 6 tests green,
      plus live detection of the Samson Meteorite.
- [x] Task 3: MicCaptureService (NAudio 2.2.1, shared mode only,
      whole-frame buffering, monotonic-from-START timestamps, STOP drain
      with no short frames). Evidence: MicCaptureServiceTests, 8 tests
      green. ICaptureSink fakes drive framing/timestamp/sequence tests.
- [x] Task 4: capture to PrioritySendQueue wiring (25-frame drop-oldest
      reuse, diagnostics, tray level meter plus channel selector).
      Evidence: ControlConnectionAudioTests, 8 loopback tests green;
      TrayAudioTests, 3 tests green.
- [x] Task 5: channel-mode decision experiment. DECIDED 2026-09-08 with the owner live: voice-level
      (--channel-mode flag, tray selector, per-session channel peaks in the
      STOP log line). Blocked: this host produces no acoustic signal
      (full-scale playback still captures digital zeros), so the owner must
      speak into the mic during a session and compare the L/R peaks.
      Verdict: voice-level session peaks L=0.073 R=0.074 and room-tone peaks L=0.018 R=0.018, identical on both channels. The Meteorite is dual-mono, so mix stays the default. Note: early runs captured pure digital zeros with format, mute, and level all nominal; live signal appeared during the owner session and the early cause was not pinned down.
- [x] Task 6: wire proof that sequence resets to 0 each session.
      Evidence: loopback test plus live two-session check ([0..4] after
      restart, zero gaps, exact 20000 us timestamps).
- [x] Task 7: Windows-side validation. Done: START-to-first-frame 99.8 ms
      on LAN, 50-frame zero-gap run, silence after STOP, nack mode,
      1-frame stale tail matches the reference tolerance. Owner-run:
      6-onset first-word sample with full speech energy in the first 100 ms every time (first-frame 65-149 ms), simultaneous Teams call confirmed working,
      30-minute soak passed (90000 frames, zero gaps), simultaneous Teams call confirmed, exclusive-mode lockout proven via physical unplug (START_NACK MIC_UNAVAILABLE while out, clean recovery after replug). Exclusive mode itself is unavailable: the Meteorite driver refuses exclusive opens with DEVICE_IN_USE even with zero audio sessions after a service restart, so no app can simulate it; the exercised branch is identical (open fails, NACK).

## Owner checklist (needs ears and hands)

1. Check the Meteorite hardware mute button, then run a session while
   speaking: the STOP log line reports channel peaks L/R. Equal peaks mean
   dual-mono (keep mix); a silent right channel means left-only (switch the
   default to left).
2. 95-of-100 first-word test per spec section 9.
3. Exclusive-mode lockout: hold the mic exclusively, START, expect
   START_NACK with MIC_UNAVAILABLE.
4. 30-minute soak plus Teams/Zoom/browser capture alongside.






