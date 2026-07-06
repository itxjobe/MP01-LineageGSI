# MP01 LineageOS GSI: Finish and Ship (v1 Design)

- **Date:** 2026-07-06
- **Owner:** Josh Reid (`itxjobe`)
- **Status:** Approved shape, spec under review
- **Repo (to be created):** `itxjobe/MP01-LineageGSI` (public), standalone, with dead upstreams wired as git remotes

## 1. Context and problem

The Minimal Phone MP01 is an e-ink MediaTek Android device whose stock OS is poor. Two community efforts exist to replace it with a LineageOS 22.2 (Android 15, QPR2) Treble/phh **GSI**:

- `MP01Experiments/MP01-LineageGSI` (original, by chardidathing). Has the issue tracker and the community, but **dead since 2025-08-15**.
- `MP01-LineageOS/MP01-LineageGSI` (fork). 20 commits ahead, worked 2026-05-22 to 05-27, then dormant. It added the important-but-invisible groundwork: build-reliability hardening, a **microG build variant**, SHA-pinned reproducible release inputs, a first-boot defaults scaffold, and a SetupWizard launcher patch.

The fork's defining failure: **it did the plumbing and never shipped a single build.** Its only "release" re-points to the exact same byte-identical August 2025 image as upstream (0 downloads). Every improvement lives in unbuilt source. Both repos are currently unmaintained.

This is not a device port. It is a generic ARM64 system image flashed on top of the MP01's **stock MediaTek vendor**. That split matters: software-configurable behaviour (defaults, animations, build, OTA) is winnable; anything in the vendor/kernel (proximity sensor during calls, panel blanking) has a hard ceiling and is explicitly out of v1.

We are taking the fork as our base (it has the groundwork) and doing what it never did: **build it reproducibly, make it boot right with zero manual steps, tame the e-ink experience, and ship it with a working update path.**

## 2. Goal and success criteria (v1)

A single, opinionated **microG** image for the MP01 that:

1. **Builds reproducibly on the ROG** from our repo, signed with our own keys, no bespoke container required.
2. **Boots fully usable on a clean flash with zero manual fixes.** All six of the current README "workarounds" are gone.
3. **Feels right on e-ink:** animations that cause ghosting are eliminated or heavily reduced; boot/shutdown are e-ink friendly.
4. **Updates over the air, or a documented fallback.** A new build is delivered through the in-OS updater and applies. Owner has confirmed working OTA is **not a hard v1 gate**: if in-OS OTA proves infeasible for a GSI, a documented and verified reflash-based update path satisfies v1 and #32 is reopened.

Before any of this touches hardware, a **verified stock backup and restore path** must exist (see P0). v1 is proven done when: with a known-good restore path in hand, we flash our signed microG image to Josh's actual MP01, complete setup touching none of the old workarounds, observe reduced ghosting, then update to a second build (OTA if available, else documented reflash).

## 3. Non-goals (explicitly out of v1)

- **Vendor/kernel-bound bugs:** proximity dimming in call (#1), display not blanking on sleep (#5). Documented as known issues; investigated only if the MP01 kernel/vendor turns out to be accessible.
- **CI / release automation (M4)** and **polished docs: unbrick / return-to-stock / guides (M5).** Fast-follows, designed to ride the rails v1 builds. Note the return-to-stock *capability* (a working, verified backup and restore) is pulled into v1 as P0; only the polished public guide is deferred to M5.
- **GMS and vanilla polish.** Both still build (we do not break them), but microG is the only flavor we tune and OOB-default for v1.
- **VoWiFi (#11), AOD (#7), styled wallpapers (#16).** Deferred.

## 4. Constraints and environment

- **Builder:** ROG (`ssh rog`, Tailscale-only). Pop!_OS 24.04, Ultra 9 185H, 22 threads, 30 GB RAM + 19 GB swap, **767 GB free**. Needs `repo`, `ccache`, `aapt`/build-tools, a JDK, and standard AOSP build deps installed. The fork's thread-throttle knobs (`SOONG_FINDER_THREADS`, `BLUEPRINT_PARSE_THREADS`, serial `make`) exist precisely for a RAM-constrained host and will be used.
- **Cockpit:** Mac Mini M1 (this machine). Edits scripts, patches, overlays, git. Cannot build AOSP (Apple Silicon/macOS). Drives the ROG over SSH.
- **Not used:** Claude Code cloud / rented VMs. The ROG is the builder for v1.
- **Device:** one physical MP01 (Josh's) is the sole hardware test target. Bootloader unlocked, vbmeta verification disabled per `vendor/MP01_services/README.md`.
- **Licensing:** repo is MIT except AOSP-derived files under Apache-2.0 (e.g. `HardwareGestureDetector.kt`). Preserve all third-party legal attribution. No AI/Claude authorship anywhere. No em dashes in user-facing copy.

## 5. Repo and branching strategy

- Create **`itxjobe/MP01-LineageGSI`**, public, as a clean standalone repo (not a GitHub fork-of-a-fork, so it gets its own issues, releases, and identity).
- Remotes on the local clone: `origin` = itxjobe, `upstream-fork` = `MP01-LineageOS`, `upstream-orig` = `MP01Experiments`. This lets us cherry-pick from either dead upstream.
- Default branch stays `15` (matches upstream convention and the manifest branch names).
- Work proceeds on feature branches, one per milestone, one commit per meaningful step, per Josh's Tier 2/3 build convention.
- `scripts/release-inputs.sh` pins point at the fork today; we re-point `MP01_RELEASE_REPO`, `MP01_SUPPORT_REPO`, `MP01_OTA_JSON_URL` to `itxjobe/...` as part of M0.

## 6. Architecture overview

**Build pipeline (per flavor):** `repo init` LineageOS 22.2 with treble + (for microG) the `microg` group → sync → clone our support repo → apply TrebleDroid + MP01 patches → generate treble makefiles, swap in our `treble_arm64_bmN.mk` (microG), `bgN` (gapps), `bvN` (vanilla) → copy `vendor/` additions → fetch SHA-pinned FinQwerty + F-Droid + treble presets → `lunch treble_arm64_bmN-bp1a-userdebug` → `make target-files-package otatools` → sign → package image + OTA.

**Three flavors, one support tree.** microG is `treble_arm64_bmN` using repo groups `default,microg` and `vendor/partner_gms` (GmsCore, FakeStore, GsfProxy, FDroid, FDroidPrivilegedExtension), with `vendor_gapps` and the standalone privileged-extension removed. We do not disturb `bgN`/`bvN`.

**Where our changes live:**
- `vendor/MP01_services/` is the home for device behaviour. It already contains: `mp_keyboard` (aw9523b IDC/KL/KCM keylayout files), `MP01_accessibility_service` (first-boot defaults, today only sets light mode), `MP01_eink_daemon` (native e-ink helper), `MP01_services.mk`, `Android.bp`, and `sepolicy`. OOB defaults (M2) and e-ink behaviour (M3) extend this package.
- `patches/` holds TrebleDroid + MP01 source patches (e.g. the SetupWizard launcher patch, Soong/Blueprint thread caps). RRO overlays for animation/theme/QS tweaks are added here or as a product overlay.
- Build entry points: `buildmicrog.sh` (flagship), `buildgms.sh`, original `build.sh`. `scripts/release-inputs.sh` centralizes pinned inputs and portable download/verify helpers.

## 7. Milestones

### P0 - Device safety: stock backup and verified restore (prerequisite, hard gate)

Owner requirement: a full backup and a proven way back to the stock OS **before anything is flashed**. This is a hard gate on every on-device step below, and it also delivers what open issue #22 (return-to-stock) never had.

Work:
1. Locate or capture the MP01 stock firmware. For this MediaTek device that means the stock partition set / scatter (via the vendor firmware if obtainable, or a full partition dump over fastboot/`dd` while access exists), including `boot`, `vbmeta`, `super`/`system`/`product`, and anything the current OS occupies.
2. Store the backup off-device (on the Mac cockpit, checksummed).
3. **Verify the restore actually works** by flashing stock back at least once, so the path is proven and not theoretical.
4. Write the minimal restore steps down (seed of the future #22 guide).

Exit: a checksummed stock backup on the Mac and a restore procedure that has been executed successfully at least once. No image gets flashed for M0 until this passes.

### M0 - Repo bring-up and first green signed microG build

Current state: `buildmicrog.sh` is **coupled to a Codex build container**. Lines 27-37 source `${CODEX_HOME:-$HOME/.codex}/lib/codex_container/workspace_paths.sh` and hard-exit if absent; it calls `codex_require_large_state_path` and `codex_check_free_space_gib` from that lib. It also produces an **unsigned** image (no signing, no OTA). `release-inputs.sh` itself is portable and SHA-pins everything.

Work:
1. Create the GitHub repo, push, re-point release-input pins to `itxjobe`.
2. Prep the ROG: install `repo`, `ccache`, `aapt`/sdk build-tools, JDK, AOSP build deps; set `ccache -M 200G`; confirm case-sensitive build volume (the script checks this).
3. Generate our own release signing keys into `~/.android-certs` (LineageOS `make_key` for the standard cert set).
4. **De-containerize the build:** make the `codex_container` helper optional. Provide a small portable shim implementing `codex_require_large_state_path` (assert path exists on a large volume) and `codex_check_free_space_gib`, or gate the sourcing behind a flag and set `MP01_ALLOW_NON_WORKSPACE_BUILD=1`. Prefer a clean portable wrapper over patching every call site.
5. **Add signing to the microG flow:** extend `buildmicrog.sh` (or factor a shared `sign-and-package.sh`) to sign the target-files package and produce a signed `system.img` + signed OTA package, mirroring what `build.sh` already does for the vanilla flavor.
6. Run it end to end on the ROG. Fix breakages. Deliverable: one signed microG `system.img` we can fastboot to the device per the README procedure.

Exit: signed microG image built on the ROG and flashed to the MP01, booting to setup.

### M1 - Working update path (fixes #32)

Current state: `ota.json` points at a `.tar.gz` of a raw `system.img`. The in-OS updater fetches the `date` field fine, then fails because it cannot apply a tar.gz as an OTA. `MP01_OTA_JSON_URL` shows the updater reads `ota.json` from the repo's `15` branch.

Work:
1. **Research spike (the one genuine unknown):** identify exactly what consumes `ota.json`. Likely the LineageOS Updater pointed via overlay at our URL, or a treble-specific updater. Determine the package format and delivery it expects (flashable OTA zip vs image), and whether GSI updates apply seamlessly or require a reflash step.
2. Make the build publish the **correct** artifact (the signed OTA package the updater can apply) and point `ota.json` at that artifact, with correct size/sha/date.
3. Verify end to end on the device: install build A, publish build B, pull the OTA in-OS, confirm it applies and boots.

Exit: OTA from one of our builds to the next succeeds on the MP01.

### M2 - Out-of-box defaults (kills all six workarounds)

Current state and per-workaround plan:
- **PHH presets not applied OOB.** The fork already SHA-pins a `treble_presets` `infos.json` (`MP01_TREBLE_PRESETS_*`). Ensure presets are fetched into the image and auto-applied on first boot rather than requiring Settings > PHH > Apply presets.
- **IMS/VoLTE not set up OOB.** Automate the "Create IMS APN" + "Install IMS APK" steps (the closed issues #9/#10 did the integration; wire the trigger to first boot).
- **Keyboard layout.** Likely already handled: `mp_keyboard` installs `aw9523b-key.{idc,kl,kcm}` into `system/usr` and the keychar map matches FinQwerty's MP01 layout, so manual FinQwerty selection should be unnecessary. **Verify on device**; if confirmed, this workaround is already dead. Also address alt-layers-on-keyguard (#33) if in reach.
- **Default launcher = inkOS.** The naive `ro.launcher.home` prop broke launcher selection (#25). Use the existing SetupWizard patch (`finishSetupWizard` sets the launcher role) plus role defaults, not a prop.
- **Light theme default.** Extend the existing first-boot defaults mechanism (already sets `ui_night_mode` light).
- **Per-app refresh finickiness.** Set a sane default refresh mode (README says "balanced" is ideal) via the e-ink daemon/settings defaults.
- Plus low-cost overlay tweaks in the same pass: remove "Panda" quick settings (#12), center clock (#17).

**Mechanism decision:** the current accessibility-service approach needs an accessibility permission grant to even run, and today only sets light mode. Prefer a **privileged system app with seeded default-grants** (or the existing service promoted to priv-app with a `default-permissions` xml and its enablement seeded at build time) so first-boot defaults run reliably without user interaction. Settle the exact mechanism early in M2; `MP01_services` + `sepolicy` are already structured for a priv-app.

Exit: a clean flash completes setup with none of the six workarounds needed.

### M3 - E-ink polish (in v1 per decision)

Current state: `MP01_eink_daemon` exists; the e-ink settings app (single/double e-ink-button mappings, per-app refresh) is integrated. Animations across the OS cause ghosting (#23); boot/shutdown animations are not e-ink friendly (#31).

Work:
1. **Kill animations globally:** default `window_animation_scale`, `transition_animation_scale`, `animator_duration_scale` to 0 via the first-boot defaults; disable the QS slide and other slide transitions via overlay where a scale of 0 does not cover them.
2. **E-ink boot/shutdown animation (#31):** ship a minimal high-contrast bootanimation.zip (static or few-frame) suited to e-ink instead of the animated default.
3. Sanity pass on remaining high-ghost interactions (unlock gesture, list scrolling) and reduce where cheap. Deep per-screen pagination is out of scope for v1.

Exit: on-device, ghosting during normal navigation is visibly reduced and boot/shutdown look intentional on e-ink.

## 8. Key unknowns and research spikes

1. **OTA consumer/format (M1).** The single genuine research spike. Everything else is known-mechanism work.
2. **De-containerization surface (M0).** Believed thin (two `codex_*` functions + one sourced file). Confirm nothing else in the build graph assumes the container (mount layout, noexec /tmp handling is already parameterized via `TMPDIR`).
3. **OOB defaults reliability (M2).** Whether the priv-app + seeded-grant path applies defaults reliably on first boot across a factory reset. Validate on device.

## 9. Signing and keys

- Generate our own release key set (`releasekey`, `platform`, `shared`, `media`, `networkstack`, etc.) into `~/.android-certs` on the ROG via LineageOS `make_key`.
- Consequence: our first build is a clean-flash; images signed by the old maintainer's keys cannot OTA across the key change. Expected and acceptable for a new project. From our first build onward, OTA works within our key.
- Keys live only on the ROG, never committed. Documented (not stored) so builds are reproducible by whoever holds the keys.

## 10. Testing and verification

- **Build verification:** each flavor at minimum compiles; microG additionally signs and packages. `verify-release-inputs.sh` gates pinned-input integrity.
- **On-device (the real gate), on Josh's MP01:**
  - P0: stock backup captured and its restore executed successfully at least once (gates everything below).
  - M0: signed microG image boots to setup.
  - M1: update A to B applies and boots (OTA if available, else documented reflash).
  - M2: clean flash, complete setup with zero workarounds; each of the six defaults confirmed.
  - M3: ghosting visibly reduced; boot/shutdown e-ink friendly.
- No emulator target (GSI behaviour on real MP01 hardware, especially e-ink and keyboard, is the point).

## 11. Risks and mitigations

- **RAM-constrained build on 30 GB.** Mitigation: the fork's thread caps + serial make + 19 GB swap + 767 GB disk headroom; fall back to serial `make_jobs=1` (the default) if OOM.
- **OTA spike inconclusive.** Owner-confirmed this is not a hard gate. Mitigation: if in-OS OTA cannot be made to work for a GSI in a reasonable window, fall back to a documented reflash-based update for v1 and reopen #32; do not let it block M2/M3 shipping.
- **De-containerization drags.** Mitigation: if the fork's microG script fights us, port the microG logic onto the already-portable original `build.sh` structure instead of unpicking the container script.
- **Bricking the one test device.** Mitigation: P0 is a hard gate. No image is flashed until a stock backup exists and its restore has been executed successfully at least once.
- **Both upstreams dead.** Low risk given remotes are wired for cherry-picking; we own the base now.

## 12. Fast-follows (post-v1)

- **M4 - CI + release automation:** self-hosted GitHub Actions runner on the ROG; on tag/dispatch build all three flavors, sign, publish release, update `ota.json`. Make `build.sh` fault-tolerant (#13, #14).
- **M5 - Docs:** unbrick guide (#21), return-to-stock (#22), flashing/OTA guides (#18).
- Vendor-bound bug investigation (#1, #5) if kernel access proves feasible.

## 13. Open questions for the plan

- Exact OOB-defaults mechanism (priv-app vs promoted accessibility service) - decide first thing in M2.
- Whether keyboard default (#29) is already solved by the shipped keychar map - a one-check verification on device.
- OTA format - resolved by the M1 spike before any M1 build work.
