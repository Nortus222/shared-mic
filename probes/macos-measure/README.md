# macos-measure: headless Phase 3 measurement tools

Scriptable demand for the headless measurement suite
(`macos/SharedMicTests/MeasurementTests.swift`), so the Phase 3 numbers can
be produced with no human clicking and no real application.

## DemandDriver

Opens BlackHole input (AUHAL, silent callback — never touches sample data)
for a fixed hold, printing parseable open/close timestamps. This is what
gives `AudioDemandObserver` a real cross-process demand edge with known
timing.

```sh
swiftc -O -o /tmp/DemandDriver probes/macos-measure/DemandDriver.swift
/tmp/DemandDriver --hold-ms 1500          # hold BlackHole input for 1.5 s
/tmp/DemandDriver --hold-ms 1500 --dual   # also hold the default input (multi-device shape, best effort)
```

Stdout: `PID <pid>`, `OPEN <unix-ms>`, `CLOSE <unix-ms>` (`DUAL ok|miss`
with `--dual`). Exits 2 when BlackHole is missing, 3 on unit failure.

Manual use: run it in one terminal and `./demand-probe --watch` (from
`probes/macos-demand/`) in another to watch a demand edge appear and clear.

## MeasurementTests env knobs

- Default: hermetic (fake observer legs + Python mock). Needs only
  `harness/.venv` and `swiftc`.
- `SHAREDMIC_MEASURE_HOST` / `SHAREDMIC_MEASURE_PORT` /
  `SHAREDMIC_MEASURE_PAIRING`, or `/tmp/sharedmic-measure.json` with keys
  `host`/`port`/`pairing`/`rounds`: pair with the real Windows agent instead
  of the mock. The JSON file exists because `xcodebuild test` does not
  propagate the parent shell's environment to the test host in this setup;
  it carries a bearer secret, so `chmod 600` it and delete it after the run.
  Reported numbers from such a run are end-to-end; mock runs are labeled
  Mac-side-only.
- `SHAREDMIC_MEASURE_ROUNDS`: activation-loop repetitions (default 5 for
  suite speed; 100 for the §9 verdict).

Results print as `MEASURE ...` lines in the test log. What each leg proves
is documented on the test itself.
