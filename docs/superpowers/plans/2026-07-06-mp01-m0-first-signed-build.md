# MP01 M0: First Signed microG Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reproducible, signed microG LineageOS 22.2 GSI (`treble_arm64_bmN`) built on the ROG from our own repo, ready to flash to the MP01.

**Architecture:** Take the fork's `buildmicrog.sh` (currently locked to a Codex build container and producing an unsigned image), make it portable, get a first UNSIGNED build green to prove the toolchain, then add signing with our own keys. Build on the ROG (Linux); drive from the Mac over SSH. Incremental: de-containerize and prove the build before layering signing on top.

**Tech Stack:** LineageOS 22.2 (Android 15/QPR2), TrebleDroid/phh treble, `repo`, `ccache`, Soong/Make, microG via `vendor/partner_gms`, bash. Host: Pop!_OS 24.04 on the ROG.

## Global Constraints

- Build host = ROG (`ssh rog`), Pop!_OS 24.04, 22 threads, 767 GB free, 30 GB RAM + 19 GB swap. ext4 (case-sensitive, satisfies the build's case check).
- Flagship = microG (`treble_arm64_bmN`, repo groups `default,microg`, `vendor/partner_gms`). Do not break `bgN`/`bvN`.
- Repo = public `itxjobe/MP01-LineageGSI`, branch `15`. Author commits as `Josh Reid <jreid.droid@gmail.com>`. No AI/Claude authorship. No em dashes in user-facing copy. Preserve MIT + Apache-2.0 attribution in `vendor/MP01_services/`.
- Own release keys in `~/.android-certs` on the ROG; never commit keys.
- SHA-pinned inputs via `scripts/release-inputs.sh`; re-point pins to `itxjobe`.
- RAM-constrained: prefer `MP01_MAKE_JOBS=1` (serial make), `SOONG_FINDER_THREADS=1`, `BLUEPRINT_PARSE_THREADS=1`; rely on swap.
- No personal device identifiers (serial, ME_ID, SOC_ID) committed to the public repo.

---

## File Structure

- Create: `scripts/portable-workspace.sh` — portable implementations of the `codex_*` helpers so the build runs outside the Codex container.
- Modify: `buildmicrog.sh` — source the portable shim when the Codex helper is absent; keep Codex path working.
- Modify: `scripts/release-inputs.sh` — re-point `MP01_RELEASE_REPO`/`MP01_SUPPORT_REPO`/`MP01_OTA_JSON_URL` to `itxjobe`.
- Create: `scripts/sign-microg.sh` — sign the microG target-files package and emit a signed system image + OTA.
- Modify: `docs/restore/device-state.md` — redact personal device IDs before the repo goes public.

---

### Task 1: Scrub personal IDs and create the public repo

**Files:**
- Modify: `docs/restore/device-state.md`
- Modify: `scripts/release-inputs.sh`

- [ ] **Step 1: Redact personal device identifiers**

In `docs/restore/device-state.md`, replace the device serial, `ME_ID`, and `SOC_ID` values with `REDACTED (personal, kept in ~/brain)`. Keep all generic findings (stock A14, A/B, unprotected BROM, macOS unlock gotcha).

- [ ] **Step 2: Re-point release-input pins to itxjobe**

In `scripts/release-inputs.sh` set:
```bash
: "${MP01_RELEASE_REPO:=itxjobe/MP01-LineageGSI}"
: "${MP01_SUPPORT_REPO:=https://github.com/itxjobe/MP01-LineageGSI.git}"
: "${MP01_OTA_JSON_URL:=https://raw.githubusercontent.com/itxjobe/MP01-LineageGSI/15/ota.json}"
```
Leave the finqwerty/f-droid/treble_presets/manifest pins pointing at the existing sources for now (they still resolve); note them for a later mirror.

- [ ] **Step 3: Consolidate work onto branch 15 and commit**

```bash
cd ~/projects/personal/MP01-LineageGSI
git add docs/restore/device-state.md scripts/release-inputs.sh
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "M0: redact personal device IDs; point release inputs at itxjobe"
git checkout 15 && git merge --ff-only p0/device-safety
```
Expected: `15` fast-forwards to include all spec/plan/P0 work.

- [ ] **Step 4: Create the public repo and push**

```bash
gh repo create itxjobe/MP01-LineageGSI --public --source=. --remote=origin --description "LineageOS 22.2 microG GSI for the Minimal Phone MP01" --push
git push -u origin 15
```
Expected: repo exists at `github.com/itxjobe/MP01-LineageGSI`, branch `15` pushed. Verify `gh repo view itxjobe/MP01-LineageGSI` shows the tree.

---

### Task 2: ROG build-environment prep

**Files:** none (host setup).

- [ ] **Step 1: Install AOSP build dependencies on the ROG**

```bash
ssh rog 'sudo apt-get update -qq && sudo apt-get install -y bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick lib32readline-dev lib32z1-dev libelf-dev liblz4-tool libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev python3 python-is-python3 openjdk-21-jdk-headless android-sdk-libsparse-utils'
```
Expected: all install. (Some `lib32*` names differ on 24.04; adjust if apt reports missing.)

- [ ] **Step 2: Configure ccache and git identity on the ROG**

```bash
ssh rog 'ccache -M 200G; git config --global user.name "Josh Reid"; git config --global user.email "jreid.droid@gmail.com"; git lfs install'
```
Expected: ccache max set; git identity set.

- [ ] **Step 3: Clone our repo on the ROG**

```bash
ssh rog 'mkdir -p ~/mp01 && cd ~/mp01 && git clone https://github.com/itxjobe/MP01-LineageGSI.git && ls MP01-LineageGSI'
```
Expected: repo cloned to `~/mp01/MP01-LineageGSI` on the ROG.

---

### Task 3: Generate release signing keys on the ROG

**Files:** none (keys live in `~/.android-certs`, never committed).

- [ ] **Step 1: Generate the LineageOS key set**

Using the LineageOS `make_key` approach (the build tree ships it; until synced, use a standalone loop with the same subject). On the ROG:
```bash
ssh rog 'mkdir -p ~/.android-certs && cd ~/.android-certs && subject="/C=US/ST=NA/L=NA/O=MP01/OU=MP01/CN=MP01/emailAddress=mp01@example.invalid"; for k in releasekey platform shared media networkstack sdk_sandbox bluetooth; do [ -f $k.pk8 ] || (openssl genrsa -3 -out $k.pem 2048 && openssl req -new -x509 -key $k.pem -out $k.x509.pem -days 10000 -subj "$subject" && openssl pkcs8 -topk8 -outform DER -in $k.pem -inform PEM -out $k.pk8 -nocrypt); done; ls'
```
Expected: `.pk8` + `.x509.pem` for each key. (When the source tree is synced in Task 5, prefer `development/tools/make_key` to guarantee the exact key set Android 15 expects; add any missing keys then.)

---

### Task 4: De-containerize `buildmicrog.sh`

**Files:**
- Create: `scripts/portable-workspace.sh`
- Modify: `buildmicrog.sh`

**Interfaces:**
- Produces: `codex_require_large_state_path <path> <label>` and `codex_check_free_space_gib <path> <min_gib>` available whether or not the Codex container helper exists.

- [ ] **Step 1: Write the portable shim**

Create `scripts/portable-workspace.sh`:
```bash
#!/usr/bin/env bash
# Portable stand-ins for the Codex container's workspace helpers, so the MP01
# build runs on a plain Linux host. Sourced by build scripts when the Codex
# helper ($CODEX_HOME/lib/codex_container/workspace_paths.sh) is absent.
codex_require_large_state_path() {
    local path="${1:?path required}"; local label="${2:-$path}"
    mkdir -p "$path" || { echo "ERROR: cannot create $label at $path" >&2; return 1; }
}
codex_check_free_space_gib() {
    local path="${1:?path required}"; local min_gib="${2:?min gib required}"
    local avail_gib
    avail_gib="$(df -PBG "$path" | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
    if [[ -z "$avail_gib" || "$avail_gib" -lt "$min_gib" ]]; then
        echo "ERROR: need ${min_gib} GiB free at $path, have ${avail_gib:-0} GiB" >&2
        return 1
    fi
    echo "Free space at $path: ${avail_gib} GiB (>= ${min_gib})"
}
```

- [ ] **Step 2: Make `buildmicrog.sh` source the shim when the Codex helper is missing**

Replace the hard-exit block (the `workspace_paths_helper` `if`/`else` around lines 30-37) so it falls back to the portable shim:
```bash
workspace_paths_helper="${CODEX_HOME:-$HOME/.codex}/lib/codex_container/workspace_paths.sh"
if [[ -f "$workspace_paths_helper" ]]; then
    source "$workspace_paths_helper"
else
    source "$script_dir/scripts/portable-workspace.sh"
    export MP01_ALLOW_NON_WORKSPACE_BUILD="${MP01_ALLOW_NON_WORKSPACE_BUILD:-1}"
fi
```

- [ ] **Step 3: Syntax check and commit**

```bash
cd ~/projects/personal/MP01-LineageGSI
chmod +x scripts/portable-workspace.sh
bash -n scripts/portable-workspace.sh buildmicrog.sh && echo "syntax OK"
git add scripts/portable-workspace.sh buildmicrog.sh
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "M0: de-containerize buildmicrog.sh with a portable workspace shim"
git push origin 15
```
Expected: syntax OK, pushed. The ROG clone pulls this in Task 5.

---

### Task 5: First green UNSIGNED microG build

**Files:** none (runs the build on the ROG).

- [ ] **Step 1: Pull our changes on the ROG and launch the build**

```bash
ssh rog 'cd ~/mp01/MP01-LineageGSI && git pull && MP01_MAKE_JOBS=1 SOONG_FINDER_THREADS=1 BLUEPRINT_PARSE_THREADS=1 MP01_ALLOW_NON_WORKSPACE_BUILD=1 nohup bash buildmicrog.sh > ~/mp01/build.log 2>&1 &'
```
This runs `repo init` + sync (~100 GB, tens of minutes) then the build (hours). Run detached; monitor `~/mp01/build.log`.

- [ ] **Step 2: Monitor sync and build to completion, fixing breakages**

Watch `ssh rog 'tail -f ~/mp01/build.log'`. Expected failure classes and fixes: missing `lib32*`/tool package (apt-install it), repo sync flakiness (the script already retries serially), OOM during make (already `-j1`; ensure swap is active). Iterate until `make target-files-package otatools` completes and the script prints `Image file: .../MP01-Lineage-<ts>-microG-unsigned.img`.

Exit: an unsigned microG `system.img` exists on the ROG under `~/mp01/MP01-LineageGSI/images/`.

---

### Task 6: Add signing and produce the signed image

**Files:**
- Create: `scripts/sign-microg.sh`

**Interfaces:**
- Consumes: the microG target-files package from the build, keys in `~/.android-certs`.
- Produces: a signed `system.img` (and OTA package for M1).

- [ ] **Step 1: Write the signing wrapper**

Create `scripts/sign-microg.sh` that runs `sign_target_files_apks` with `~/.android-certs`, then extracts `IMAGES/system.img` from the signed package (mirroring the vanilla `build.sh` + `sign.sh` flow), producing `MP01-Lineage-<ts>-microG-signed.img`. Reference the existing `sign.sh` and `build.sh` for the exact `ota_from_target_files`/extraction invocation so the two flavors stay consistent.

- [ ] **Step 2: Sign the build output on the ROG**

```bash
ssh rog 'cd ~/mp01/MP01-LineageGSI && bash scripts/sign-microg.sh'
```
Expected: a signed system image is produced with no signing errors.

- [ ] **Step 3: Commit the signing script and push**

```bash
cd ~/projects/personal/MP01-LineageGSI
git add scripts/sign-microg.sh
GIT_AUTHOR_NAME="Josh Reid" GIT_AUTHOR_EMAIL="jreid.droid@gmail.com" GIT_COMMITTER_NAME="Josh Reid" GIT_COMMITTER_EMAIL="jreid.droid@gmail.com" \
git commit -m "M0: add microG signing wrapper"
git push origin 15
```
Expected: pushed.

Exit (M0 complete): a signed microG `system.img` built reproducibly on the ROG from `itxjobe/MP01-LineageGSI`, ready for the M0 flash step (unlock on Linux, then fastboot flash) which is gated by P0.

---

## Self-Review

**Spec coverage (M0 section):** de-containerize (Task 4), signing (Task 6), ROG prep + keys (Tasks 2-3), first green build (Task 5), repo bring-up + re-point pins (Task 1). All covered.

**Placeholder scan:** Task 6 Step 1 references the existing `sign.sh`/`build.sh` rather than duplicating their exact `ota_from_target_files` line; that is deliberate reuse of in-repo code, not a placeholder. Task 5 Step 2 is an iterate-to-green task because compile breakages are not knowable in advance; its exit criterion is concrete.

**Consistency:** `~/mp01/MP01-LineageGSI` (ROG checkout), `~/.android-certs` (keys), `scripts/portable-workspace.sh`, `MP01_MAKE_JOBS=1` used consistently. Branch `15` is the single pushed branch.

**Deferred to M1:** OTA `ota.json` wiring uses the signed OTA package produced here; the updater-format spike is M1, not M0.
