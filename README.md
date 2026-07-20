# Running Race

Connect IQ data field for marathon racing on Garmin Fenix 8.

## Highlights

- 16-field circular race layout
- Smoothed current pace, lap pace, average pace, 5-minute rolling pace
- Race Reserve %, HR drift detection, 5 km feedback, nutrition alerts
- Power, cadence, HR, vertical ratio, GPS and chest strap status

## Build & run

### Quick way (recommended)

`run.ps1` compiles and launches the field in the Connect IQ simulator in one
step. Run it from this folder in a PowerShell terminal:

```powershell
.\run.ps1                 # build + launch on fenix843mm (default)
.\run.ps1 -BuildOnly      # compile only, no simulator
.\run.ps1 -Device fr965   # target a different device
```

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

## Repo Notes

- `bin/` and signing keys are ignored through `.gitignore`.
- Keep `source/` and `resources/` under version control.
