# Running Race

Connect IQ data field for marathon racing on Garmin Fenix 8.

## Highlights

- Pace-first circular race layout: current pace as the hero value, colour-coded
  against your target (green on pace · orange too fast · red too slow)
- Smoothed current pace, with Ø-pace for the race and L-pace for the current
  kilometre right underneath it; 5-minute rolling pace feeds the finish projection
- Race Reserve %, HR drift detection, 5 km feedback, nutrition alerts
- Two arcs: race progress across the top, HR zones along the bottom — the HR one
  zoomed to 100 bpm–zone 5, so the range you actually race in fills the whole bar
- Phone and chest-strap connection status

## Build & run

### Quick way (recommended)

`run.ps1` compiles and launches the field in the Connect IQ simulator in one
step. Run it from this folder in a PowerShell terminal:

```powershell
.\run.ps1                 # build + launch on fenix843mm (default)
.\run.ps1 -BuildOnly      # compile only, no simulator
.\run.ps1 -Test           # build + run the unit tests
.\run.ps1 -Device fr965   # target a different device
.\run.ps1 -Shot           # build + launch + save bin\sim_shot.png (screenshot)
```

`-Shot` captures the simulator window to `bin\sim_shot.png` (gitignored) so the
rendered layout can be reviewed without taking a manual screenshot.

It auto-detects the SDK (even if it is not on your PATH), signs with
`developer_key_pkcs8.der`, builds with `-w` (warnings-as-errors), and reuses an
already-open simulator instead of starting a second one.

### Manual way

1. Install the Connect IQ SDK (via the SDK Manager).
2. Add the SDK's `bin\` folder to your PATH, or use the full path to `monkeyc.bat`.
3. Create your own developer key (or use the existing `.der`). Do not commit private keys.
4. Build from the project root:

```powershell
monkeyc -f monkey.jungle -o bin\Running_Race.prg -y your_key.der -d fenix843mm -w
```

5. Run in the simulator — start it first, then load the app:

```powershell
connectiq                                   # start the simulator, leave open
monkeydo bin\Running_Race.prg fenix843mm    # load the app into it
```

## Tests

**Run these before flashing a build you intend to race with.**

```powershell
.\run.ps1 -Test
```

This builds `test.jungle` (the normal sources plus `test/`) with `--unit-test`
and runs the Run No Evil suite in the simulator. It exits non-zero if anything
fails, so it can gate a commit.

The suite drives the real `RaceEngine.tick()` — the same entry point the watch's
`compute()` uses — through a synthetic race: standing on the start line, 30 min
on pace, an auto-pause shoe stop, a 9:55/km crawl, a GPS dropout, then the rest
of the 42 km. On top of the usual value assertions it checks the things that
actually take a data field down mid-run: that the sample buffers stay bounded,
that memory does not grow over an hour of racing, that a 12 km GPS jump is
absorbed in one step, and that hostile sensor data (null, negative, absurd, a
clock that steps backwards) never throws.

The marathon test takes a minute or two. That is the point — the crash it guards
against only appears once the buffers have filled up.

## Troubleshooting

- **`.\run.ps1 : ... die Ausführung von Skripts ... deaktiviert` / "running scripts
  is disabled"** — PowerShell's execution policy blocks `.ps1` files. Enable local
  scripts once (per user, persistent):

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  ```

- **Simulator shows `Signature check failed on file: RUNNING_RACE`** — the developer
  key must be **4096-bit RSA**. A 2048-bit key compiles fine but fails the runtime
  signature check. Regenerate:

  ```powershell
  openssl genrsa -out developer_key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key_pkcs8.der -nocrypt
  ```

  then rebuild and reload. (Only reuse an old key if the app is already published on
  the IQ store under it — store updates must keep the same signing key.)

- **The field froze during a run and was gone from the data screen after a reboot** —
  that is the watchdog: `compute()` stopped returning, so Garmin killed the field
  and removed it. It is not a signature or install problem, and `try/catch` cannot
  catch it. Look for a loop in the update path that fails to make progress. The
  July 2026 instance was `trimSamples()` using `Array.remove(0)`, which removes by
  *value* — no pace sample is ever `0`, so the ring buffer never shrank and the
  trim loop spun forever once it filled (~10 min of running). `.\run.ps1 -Test`
  now covers this class of failure; run it before racing.

## Repo Notes

- `bin/` and signing keys are ignored through `.gitignore`.
- Keep `source/` and `resources/` under version control.
