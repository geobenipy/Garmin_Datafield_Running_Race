# Running Race

Connect IQ data field for marathon racing on Garmin Fenix 8.

## Highlights

- 16-field circular race layout
- Smoothed current pace, lap pace, average pace, 5-minute rolling pace
- Race Reserve %, HR drift detection, 5 km feedback, nutrition alerts
- Power, cadence, HR, vertical ratio, GPS and chest strap status

## Build

1. Install the Connect IQ SDK.
2. Create your own developer key. Do not commit private keys.
3. Build from the project root:

```powershell
& "C:\Path\To\ConnectIQ\bin\monkeyc.bat" -f monkey.jungle -o bin\Running_Race.prg -y your_key.der -d fenix843mm -w
```

## Repo Notes

- `bin/` and signing keys are ignored through `.gitignore`.
- Keep `source/` and `resources/` under version control.
