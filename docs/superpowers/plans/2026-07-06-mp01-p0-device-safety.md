# MP01 P0: Device Safety (Stock Backup and Verified Restore) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a checksummed full backup of Josh's MP01 and a restore procedure that has been executed successfully at least once, so no later OS work can brick the only test device.

**Architecture:** This is the P0 hard gate from the v1 spec. It touches hardware only, produces no OS changes. We discover the device's current state, take a full MediaTek partition backup (BROM readback via mtkclient, the gold-standard method that also enables unbrick), secure an authoritative stock image, write a restore runbook (the seed of open issue #22), and then prove the restore path by executing a full flash-back once. Backup blobs live off-repo; only scripts, checksums, and the runbook are committed.

**Tech Stack:** adb/fastboot (already on the Mac at `~/Library/Android/sdk/platform-tools`), mtkclient (MediaTek BROM tool, to install), bash, sha256.

## Global Constraints

- Device: Minimal Phone MP01, MediaTek SoC, e-ink. Bootloader unlockable; vbmeta verification disabled for GSI use.
- P0 is a **hard gate**: no non-stock image is flashed to the device until this plan's final task passes.
- Author all commits as `Josh Reid <jreid.droid@gmail.com>`. No AI/Claude authorship in commits, code, or docs. No em dashes in user-facing copy.
- Backup blobs (multi-GB) are stored at `~/mp01-backups/` (off-repo) and never committed. Only `scripts/`, `docs/restore/`, and checksum manifests go in git.
- New host tools (e.g. Homebrew `libusb`) must be flagged to Josh before install per the no-brew-without-flagging rule.
- Repo: `~/projects/personal/MP01-LineageGSI`, branch for this work: `p0/device-safety`.
- adb binary: `~/Library/Android/sdk/platform-tools/adb`; fastboot alongside it.

---

## File Structure

- Create: `scripts/backup-device.sh` — wraps the full mtkclient readback into `~/mp01-backups/<label>/`.
- Create: `scripts/restore-device.sh` — restores a chosen backup or stock image to the device.
- Create: `docs/restore/mp01-return-to-stock.md` — the human runbook (seed of issue #22).
- Create: `docs/restore/device-state.md` — captured facts about the device (state at backup time).
- Create: `backup/MANIFEST.sha256` — checksums of the backup set (checksums only, not the blobs).
- Modify: `.gitignore` — exclude backup blobs and local scratch.

---

### Task 1: Cockpit tooling and device-state discovery

**Files:**
- Create: `docs/restore/device-state.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: a recorded determination of `DEVICE_STATE` = `stock` or `gsi`, plus bootloader-unlock status, active slot, and partition list. Tasks 2 and 3 branch on `DEVICE_STATE`.

- [ ] **Step 1: Add backup ignores so no blob is ever committed**

Append to `.gitignore`:
```
# P0 device-safety local artifacts (never commit blobs)
/backup/*.img
/backup/*.bin
/backup/dump/
mp01-backups/
```

- [ ] **Step 2: Connect the phone and confirm it is seen**

Plug the MP01 into the Mac via USB. With the device booted and USB debugging on:
```bash
~/Library/Android/sdk/platform-tools/adb devices -l
```
Expected: one device listed with a serial (not `unauthorized`; accept the RSA prompt on the phone if shown).

- [ ] **Step 3: Capture the running build identity**

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
$ADB shell getprop | grep -Ei 'ro.build.(fingerprint|version.release|display.id)|ro.product.(model|device)|ro.lineage'
```
Expected: prints build fingerprint/model. If any `ro.lineage.*` or a treble/LineageOS fingerprint appears, `DEVICE_STATE=gsi`; if it is the Minimal Phone stock fingerprint with no LineageOS markers, `DEVICE_STATE=stock`.

- [ ] **Step 4: Capture bootloader-unlock, slot, and partition layout**

```bash
FB=~/Library/Android/sdk/platform-tools/fastboot; ADB=~/Library/Android/sdk/platform-tools/adb
$ADB reboot bootloader && sleep 5
$FB getvar unlocked 2>&1 | head -1
$FB getvar current-slot 2>&1 | head -1
$FB getvar is-userspace 2>&1 | head -1
```
Expected: `unlocked: yes` (required before any flashing), a current slot (`a`/`b` or empty if non-A/B), and userspace fastboot support. Then `$FB reboot` back to the OS.

- [ ] **Step 5: Write device-state.md and commit**

Record in `docs/restore/device-state.md`: date, `DEVICE_STATE`, fingerprint, model/device codename, unlock status, slot layout (A/B vs not), and whether userspace fastboot (`fastbootd`) is available. This drives every later branch.
```bash
cd ~/projects/personal/MP01-LineageGSI && git checkout -b p0/device-safety 2>/dev/null || git checkout p0/device-safety
git add .gitignore docs/restore/device-state.md
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "P0: record MP01 device state and add backup ignores"
```
Expected: commit succeeds on `p0/device-safety`.

---

### Task 2: Install mtkclient and take a full partition backup

**Files:**
- Create: `scripts/backup-device.sh`
- Create: `backup/MANIFEST.sha256`

**Interfaces:**
- Consumes: `DEVICE_STATE` from Task 1.
- Produces: `~/mp01-backups/<DEVICE_STATE>-<date>/` containing one `.bin` per partition plus `MANIFEST.sha256`; the manifest is copied into `backup/MANIFEST.sha256` in the repo.

- [ ] **Step 1: Flag and install the mtkclient dependency**

mtkclient needs `libusb`. Confirm with Josh before the brew install (per the no-brew rule), then:
```bash
brew install libusb            # only after Josh approves
python3 -m venv ~/.venvs/mtk && ~/.venvs/mtk/bin/pip install -U pip
~/.venvs/mtk/bin/pip install git+https://github.com/bkerler/mtkclient.git
~/.venvs/mtk/bin/mtk --help | head -3
```
Expected: mtk help prints. If macOS USB access blocks BROM mode, note it in device-state.md and fall back to running mtkclient from a Linux host (the phone plugged into that host); the rest of the plan is unchanged.

- [ ] **Step 2: Write the backup script**

Create `scripts/backup-device.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
# Full MediaTek partition readback via mtkclient BROM mode.
# Usage: scripts/backup-device.sh <label>   e.g. stock-2026-07-06
label="${1:?usage: backup-device.sh <label>}"
mtk="${MTK_BIN:-$HOME/.venvs/mtk/bin/mtk}"
out="$HOME/mp01-backups/$label"
mkdir -p "$out"
echo "Put the MP01 into BROM mode now (power off, hold volume keys, plug in USB)."
# Read every partition except userdata (huge, not needed for restore-to-clean).
"$mtk" rl "$out" --skip userdata
( cd "$out" && shasum -a 256 * > MANIFEST.sha256 )
echo "Backup written to $out"
echo "Partitions captured:"; ls -1 "$out"
```
Make it executable:
```bash
chmod +x scripts/backup-device.sh
bash -n scripts/backup-device.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Run the full backup**

```bash
cd ~/projects/personal/MP01-LineageGSI
./scripts/backup-device.sh "${DEVICE_STATE:-stock}-2026-07-06"
```
Expected: mtkclient dumps `boot`, `vbmeta`, `preloader`, `super` (or `system`/`product`/`vendor`), `lk`/`gz`/`tee`, `nvram`/`nvdata`/`protect*`, `metadata`, etc., into `~/mp01-backups/<label>/` with a `MANIFEST.sha256`. Confirm `boot.bin`, `vbmeta.bin`, and the system-bearing partition (`super.bin` or `system.bin`) are present and non-zero.

- [ ] **Step 4: Copy checksums into the repo and commit (blobs stay out)**

```bash
mkdir -p backup
cp ~/mp01-backups/"${DEVICE_STATE:-stock}-2026-07-06"/MANIFEST.sha256 backup/MANIFEST.sha256
git add scripts/backup-device.sh backup/MANIFEST.sha256
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "P0: add device backup script and checksum manifest"
git status --porcelain backup/ | grep -v MANIFEST && echo "WARNING: blob staged" || echo "only checksums tracked"
```
Expected: commit succeeds; `only checksums tracked` (no `.bin`/`.img` staged).

---

### Task 3: Secure the authoritative stock image

**Files:**
- Modify: `docs/restore/device-state.md` (append the stock source of truth)

**Interfaces:**
- Consumes: `DEVICE_STATE`, the Task 2 backup.
- Produces: `STOCK_SOURCE` = a verified, checksummed set of stock partitions on the Mac, and a recorded provenance line. Task 4/5 restore from `STOCK_SOURCE`.

- [ ] **Step 1: Decide the stock source from device state**

- If `DEVICE_STATE=stock`: the Task 2 readback **is** the authoritative stock image. Set `STOCK_SOURCE=~/mp01-backups/stock-2026-07-06`. Skip to Step 3.
- If `DEVICE_STATE=gsi`: the readback is a GSI snapshot, not stock. Continue to Step 2 to obtain a true stock image.

- [ ] **Step 2: Obtain official stock firmware (only if DEVICE_STATE=gsi)**

Locate the MP01 stock firmware from, in order of preference: the Minimal Phone vendor/support channel, the flashing guide at `chardidath.ing/posts/mp01-flashing-guide/`, or the Dumbphone Hangout Discord `#mp01-*` channels (a community stock readback is acceptable if checksum-shared). Download to `~/mp01-backups/stock-official/`, then:
```bash
cd ~/mp01-backups/stock-official && shasum -a 256 * > MANIFEST.sha256 && cat MANIFEST.sha256
```
Expected: a scatter/partition set (MediaTek SP Flash Tool format or per-partition images) with recorded checksums. Set `STOCK_SOURCE=~/mp01-backups/stock-official`.

- [ ] **Step 3: Record the stock source of truth and commit**

Append to `docs/restore/device-state.md` a `## Stock source of truth` section: the `STOCK_SOURCE` path, its provenance (self-readback vs official vs community), and its top-level checksums.
```bash
git add docs/restore/device-state.md
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "P0: record authoritative stock image source and provenance"
```
Expected: commit succeeds.

---

### Task 4: Write the restore script and return-to-stock runbook

**Files:**
- Create: `scripts/restore-device.sh`
- Create: `docs/restore/mp01-return-to-stock.md`

**Interfaces:**
- Consumes: `STOCK_SOURCE`.
- Produces: an executable restore path and a human runbook. Task 5 executes exactly these.

- [ ] **Step 1: Write the restore script**

Create `scripts/restore-device.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
# Restore a full partition set (stock or a prior backup) to the MP01 via mtkclient.
# Usage: scripts/restore-device.sh <source-dir>
src="${1:?usage: restore-device.sh <source-dir>}"
mtk="${MTK_BIN:-$HOME/.venvs/mtk/bin/mtk}"
[ -d "$src" ] || { echo "no such dir: $src" >&2; exit 1; }
echo "Verifying source checksums..."
( cd "$src" && shasum -a 256 -c MANIFEST.sha256 )
echo "Put the MP01 into BROM mode now (power off, hold volume keys, plug in USB)."
# Write back every partition present in the source (writeflash respects file names).
"$mtk" wl "$src" --skip userdata
echo "Restore complete. Reboot the device."
```
```bash
chmod +x scripts/restore-device.sh && bash -n scripts/restore-device.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 2: Write the return-to-stock runbook**

Create `docs/restore/mp01-return-to-stock.md` with exact steps: prerequisites (unlocked bootloader, `~/.venvs/mtk`), how to enter BROM mode on the MP01, `./scripts/restore-device.sh <STOCK_SOURCE>`, expected mtkclient output, first-boot expectations, and a troubleshooting note (preloader/BROM re-entry, `--serialport` fallback). Write for a reader with zero project context.

- [ ] **Step 3: Commit the restore tooling**

```bash
git add scripts/restore-device.sh docs/restore/mp01-return-to-stock.md
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "P0: add restore script and return-to-stock runbook"
```
Expected: commit succeeds.

---

### Task 5: Prove the restore (the hard gate)

**Files:**
- Modify: `docs/restore/mp01-return-to-stock.md` (append the verified-run record)

**Interfaces:**
- Consumes: `scripts/restore-device.sh`, `STOCK_SOURCE`.
- Produces: a device that has been through a full deliberate restore and booted. This is the gate that unblocks M0.

- [ ] **Step 1: Execute a full restore from the authoritative source**

Deliberately run the restore path end to end against the device:
```bash
cd ~/projects/personal/MP01-LineageGSI
./scripts/restore-device.sh "$STOCK_SOURCE"
```
Expected: source checksums verify, mtkclient writes each partition with no errors.

- [ ] **Step 2: Reboot and confirm a healthy boot**

Reboot the device and let it settle a few minutes.
```bash
~/Library/Android/sdk/platform-tools/adb wait-for-device shell getprop ro.build.fingerprint
```
Expected: the device boots and reports the expected stock fingerprint (matching `STOCK_SOURCE`). The screen reaches the stock UI.

- [ ] **Step 3: Record the verified run and commit; declare P0 passed**

Append a `## Verified restore` section to the runbook: date, `STOCK_SOURCE` used, mtkclient version, outcome (booted OK), and any deviations. This is the evidence the gate is satisfied.
```bash
git add docs/restore/mp01-return-to-stock.md
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "P0: record verified restore run; device-safety gate passed"
```
Expected: commit succeeds. P0 is now satisfied and M0's on-device flash is unblocked.

---

## Self-Review

**Spec coverage (P0 section of the spec):**
- "Locate or capture MP01 stock firmware" → Tasks 2 and 3.
- "Store the backup off-device, checksummed" → Task 2 (blobs in `~/mp01-backups`, `MANIFEST.sha256`).
- "Verify the restore actually works by flashing stock back at least once" → Task 5.
- "Write the minimal restore steps down (seed of #22)" → Task 4.
- Exit criterion "checksummed stock backup on the Mac and a restore procedure executed successfully" → Task 5 Step 3. Covered.

**Placeholder scan:** No TBD/TODO. `DEVICE_STATE` and `STOCK_SOURCE` are defined variables resolved in Tasks 1 and 3, not placeholders. Scripts are complete and syntax-checked.

**Type/name consistency:** `scripts/backup-device.sh`, `scripts/restore-device.sh`, `docs/restore/device-state.md`, `docs/restore/mp01-return-to-stock.md`, `backup/MANIFEST.sha256`, branch `p0/device-safety`, venv `~/.venvs/mtk` used consistently across all tasks.

**Known adaptation:** classic unit-test TDD does not apply to a hardware backup procedure; each task instead ends in an explicit device/command verification, per the domain.
