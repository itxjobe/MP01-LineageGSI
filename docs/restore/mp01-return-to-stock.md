# MP01 return to stock (unbrick / restore)

How to put a Minimal Phone MP01 back to its factory Android 14 image from a full mtkclient
backup. This recovers from a bad flash, a boot loop, or a soft brick, because MediaTek BROM
mode works below the bootloader and below any broken OS.

This is the seed of the community "return to stock" (issue #22) and "unbrick" (#21) guides.

## What you need

- A host with the backup set. Default source: `~/mp01-backups/stock-2026-07-06/` (61 partitions,
  ~10 GB), integrity-checked by `backup/MANIFEST.sha256` in this repo.
- mtkclient in a venv at `~/.venvs/mtk` (`~/.venvs/mtk/bin/mtk`). Host needs `libusb`.
- A USB cable. No bootloader unlock required: BROM restore bypasses lock state.

If you do not have a backup, capture one from any healthy MP01 with
`scripts/backup-device.sh <label>`; the readback is device-portable for everything except the
device-unique partitions (`nvram`, `nvdata`, `nvcfg`, `protect1/2`, `proinfo`, `seccfg`), which
must come from the same handset.

## Enter BROM mode

1. Unplug the phone.
2. Power it fully off (hold power ~10 seconds).
3. Hold **both Volume Up and Volume Down**, and while holding, plug in USB. The screen stays
   black; that is correct. mtkclient will detect the Preloader/BROM port and load its DA.

If the first handshake fails, unplug, power off again (hold power ~10s), and re-enter. mtkclient
retries automatically until it catches the handshake.

## Full restore (return to stock)

```bash
cd ~/projects/personal/MP01-LineageGSI
./scripts/restore-device.sh ~/mp01-backups/stock-2026-07-06
```

Expected: checksums verify, then each partition is written ("Writing sector ... 100%"). A full
restore includes `super` (~9 GB), so it takes roughly 15 minutes over USB.

**Important:** a full restore writes back `seccfg`, which returns the bootloader to the lock
state stored in the backup (this device was **locked** at backup time). That is intentional for a
true return to stock, and it is safe **only because the matching stock `super`, `vbmeta*`, and
`boot` are restored in the same pass**, so verified boot is satisfied. Never restore `seccfg`
alone over a modified system, and never re-lock a device that still has a GSI on it.

When it finishes, reboot: the device should boot the stock Android 14 image
(`Minimal_Phone/MP01/MP01:14/...`). If it stays black, hold power ~10 seconds to reset.

## Targeted restore (recover one or two partitions)

To rewrite only specific partitions (for example after a bad `boot` flash), pass their names:

```bash
./scripts/restore-device.sh ~/mp01-backups/stock-2026-07-06 boot_a vbmeta_a
```

## Troubleshooting

- **Handshake keeps failing:** power fully off (hold power ~10s) before each attempt; try holding
  only Volume Up, or only Volume Down; use a different cable/port; avoid USB hubs.
- **"DA not found" / auth errors:** this device was seen unprotected (DAA disabled); if a future
  unit differs, pass authenticated DA/preloader via `--preloader` / `--auth`.
- **Device won't leave BROM:** unplug and hold power ~10 seconds to force a normal boot.
- **preloader:** the eMMC preloader is not in this backup (separate boot region). It is only
  needed if the preloader itself is corrupted; capture it with
  `~/.venvs/mtk/bin/mtk r preloader preloader.bin --parttype boot1`.

## Verified restore

**2026-07-06 — P0 gate closed on backup integrity (no live write test performed).**

Owner decision: skip the physical restore rehearsal. The gate rests on:

- 61-partition backup at `~/mp01-backups/stock-2026-07-06/`, every partition non-zero.
- `shasum -a 256 -c MANIFEST.sha256` verified clean (a full 10 GB re-read).
- The full read used the same patched Download Agent that writes, and the device reported
  **unprotected** (DAA disabled, mem read/write auth true), so the write path is expected to work.

**Residual risk (accept knowingly):** the restore write has not actually been executed, so the
first real return-to-stock will be the initial live test of the write path. Mitigation if it ever
fails: the device is unprotected in BROM, so a bad DA session can be retried, and targeted
`scripts/restore-device.sh <dir> <partition>` can rewrite individual partitions.
