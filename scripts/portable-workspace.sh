#!/usr/bin/env bash
# Portable stand-ins for the Codex container's workspace helpers, so the MP01
# build runs on a plain Linux host (e.g. the ROG). The build scripts source this
# when the Codex helper ($CODEX_HOME/lib/codex_container/workspace_paths.sh) is
# absent, keeping the original container path working unchanged.

# Ensure a large-state path exists and is writable. On the container this routed
# state onto a dedicated volume; on a normal host we just make sure it exists.
codex_require_large_state_path() {
    local path="${1:?path required}"
    local label="${2:-$path}"
    mkdir -p "$path" || { echo "ERROR: cannot create $label at $path" >&2; return 1; }
    [ -w "$path" ] || { echo "ERROR: $label not writable at $path" >&2; return 1; }
}

# Fail early if the build volume does not have enough free space.
codex_check_free_space_gib() {
    local path="${1:?path required}"
    local min_gib="${2:?min gib required}"
    local avail_gib
    avail_gib="$(df -PBG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
    if [[ -z "$avail_gib" || "$avail_gib" -lt "$min_gib" ]]; then
        echo "ERROR: need ${min_gib} GiB free at $path, have ${avail_gib:-unknown} GiB" >&2
        return 1
    fi
    echo "Free space at $path: ${avail_gib} GiB (>= ${min_gib} required)"
}
