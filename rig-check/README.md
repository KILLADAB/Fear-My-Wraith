# rig-check

Read-only settings checker for the Acer Predator Helios Neo 16S AI (PHN16S-71-98RF) on HDMI to the Samsung Odyssey G93SD.

`machine.yaml` is the laptop, the pinned driver `616.92`, and the display. `profiles.yaml` is the preferred settings for iRacing, Assetto Corsa Competizione, Assetto Corsa Evo, Forza Horizon 6, and Battlefield 6. `rig-check.ps1` reads those files and the live Windows mode. It writes nothing.

## Run

On the laptop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rig-check.ps1 status
```

`selftest` checks the files and the report logic. It does not need the Odyssey attached:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rig-check.ps1 selftest
```

## What status is checking

- NVIDIA driver is exactly `616.92`, read from `nvidia-smi` when it is available.
- The external display is the Odyssey (name match, else 5120x1440, else the only external screen).
- That display is running 5120x1440.
- The connection is HDMI when Windows identifies it.
- The FPS cap to type into each game is the refresh Windows reports for that mode.

The 2560x1600 laptop panel is listed and then left alone. G-SYNC, HDR, and every in-game setting are printed for you to confirm. Game config folders for iRacing and Assetto Corsa Competizione are presence checks only. File contents are not read.

Exit `0` means the driver matches and the Odyssey is at 5120x1440, with HDMI either confirmed or not identified. Exit `2` means a live check differed or could not be compared. Exit `1` means the settings files are invalid or Windows display enumeration failed.

## Left alone

BIOS, undervolt, PredatorSense, fan curves, driver install and rollback, Windows display mode, HDR, and the NVIDIA driver profile database. There is no apply command in this phase.
