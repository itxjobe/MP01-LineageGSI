# MP01 device state (captured for P0)

**Captured:** 2026-07-06, on Josh's Mac mini, device connected via USB (debugging always-allow set).

## Determination

- **DEVICE_STATE = stock** (not the community GSI). The full BROM backup taken in P0 Task 2 is
  therefore the **authoritative stock restore source**; P0 Task 3 is satisfied by that backup.

## Identity

| Field | Value |
|---|---|
| Model / product / device | MP01 |
| Manufacturer (ODM) | ALONG |
| Serial | REDACTED (personal; kept in ~/brain) |
| Stock fingerprint | `Minimal_Phone/MP01/MP01:14/UP1A.260104.1611/mp1V1254:user/release-keys` |
| Build display id | `MP01_20260104_1412` |
| Android version | 14 (stock) |
| Security patch | 2025-11-05 |
| Treble | enabled (`ro.treble.enabled=true`) |

## Boot / partition state

| Field | Value | Implication |
|---|---|---|
| Bootloader lock | **LOCKED** (`ro.boot.flash.locked=1`, `ro.boot.vbmeta.device_state=locked`) | Must unlock before flashing; unlock wipes userdata (approved). |
| Verified boot | green | Stock, unmodified. |
| Slot layout | A/B, active slot `_b` | Flash targets current slot; GSI flash + `fastboot -w`. |
| Build type | user (`ro.secure=1`, `ro.debuggable=0`) | No root adb, cannot `dd` partitions; fastboot cannot read. |
| AVB | vbmeta avb 1.2, sha256 | GSI will need vbmeta `--disable-verity --disable-verification` (M0 concern). |

## Backup / restore method (consequence)

- Partition backup must go through **mtkclient (MediaTek BROM)**; adb/root and fastboot-read are
  both unavailable. Requires `libusb` on the host (flag to Josh) and entering BROM mode.
- **Order:** take the full BROM backup **before** unlocking, to preserve a pristine copy of
  `nvram`/`nvdata`/`protect*` (IMEI, MAC, calibration) in case unlock wipes more than userdata.
- Risk to watch: if the BROM has Serial Link Authorization (SLA/DAA) enabled, mtkclient readback
  may require authenticated DA files. If readback fails, fall back to obtaining official Minimal
  Phone firmware as the stock source.

## Stock source of truth (P0 Task 3)

- **Resolved: the P0 backup is the authoritative stock image.** `DEVICE_STATE=stock`, so the
  2026-07-06 full BROM readback captures the factory Android 14 image exactly as shipped.
- **Location:** `~/mp01-backups/stock-2026-07-06/` (off-repo, ~10 GB, 61 partitions).
- **Provenance:** self-readback from Josh's own device via mtkclient BROM mode; device reported
  unprotected (DAA disabled, mem write auth true), no SLA fallback needed.
- **Integrity:** `backup/MANIFEST.sha256` (in repo) records the SHA-256 of every partition;
  `shasum -a 256 -c MANIFEST.sha256` verified clean at capture time.
- **Gap (accepted):** the eMMC `preloader` boot region is not in the main GPT and so is not in
  this readback. Acceptable because our GSI work never writes the preloader. Can be captured
  separately with `mtk r preloader preloader.bin --parttype boot1` if a fully complete image is
  wanted later.
- **BROM device IDs:** REDACTED (ME_ID and SOC_ID are personal, device-unique; kept in `~/brain`,
  not in this public repo).

## Bootloader unlock (deferred to Linux)

- **State: still LOCKED.** `sys.oem_unlock_allowed=1` (OEM unlocking is enabled in dev options),
  so unlock is permitted; we just could not complete it from macOS.
- **macOS could not unlock this device (two methods failed, device unharmed):**
  - `mtk da seccfg unlock`: DA loaded and computed/uploaded the new seccfg, then failed at the
    flash write (`Error on writing flash at 0x02900000` / `Error on writing seccfg config`).
  - `fastboot flashing unlock`: macOS + MediaTek fastboot never communicated; `getvar` returned
    `Status read failed (No such process)` and the unlock hung; the phone booted back to stock.
- **Takeaway:** on macOS, mtkclient BROM **reads** work (the 10 GB backup succeeded), but MTK
  **writes** (seccfg) and **fastboot** are unreliable. Do unlock / flash / low-level writes from a
  **Linux host** (the ROG), where MTK tooling is solid.
- **Decision:** unlock is deferred to the start of M0's flash phase, performed on Linux. It blocks
  nothing now (P0 is complete and no GSI image exists yet).
