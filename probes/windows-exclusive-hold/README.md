# Exclusive-hold probe (Phase 2, issue 8)

Holds the pinned Meteorite endpoint in WASAPI exclusive mode so the
agent lockout path can be tested without a DAW installed.

Build and hold for 30 seconds:

```powershell
dotnet build probes/windows-exclusive-hold/ExclusiveHold
probes/windows-exclusive-hold/ExclusiveHold/bin/Debug/net10.0-windows/ExclusiveHold.exe 30
```

While it prints EXCLUSIVE HELD, send START from the mock Mac client and
expect START_NACK with MIC_UNAVAILABLE. After RELEASED, START must be
accepted again.
