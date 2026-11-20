#!/bin/bash
# Keep the live site available while a release is downloaded and installed.
set -euo pipefail

atomic_file() {
  local source_file="$1" target_file="$2" temporary
  if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then return 0; fi
  mkdir -p "$(dirname "$target_file")" || return 1
  temporary=$(mktemp "$(dirname "$target_file")/.calyx-file.XXXXXX") || return 1
  if ! cp -p -- "$source_file" "$temporary"; then rm -f -- "$temporary"; return 1; fi
  if ! mv -f -- "$temporary" "$target_file"; then rm -f -- "$temporary"; return 1; fi
}

publish_tree() {
  local source_dir="$1" target_dir="$2" file phase listing
  # Jailed cPanel shells may not expose /dev/fd, so avoid process substitution.
  listing=$(mktemp "${CALYX_RUN_TMP:-${TMPDIR:-/tmp}}/calyx-files.XXXXXX") || return 1
  if ! find "$source_dir" -type f -print0 > "$listing"; then rm -f -- "$listing"; return 1; fi
  # Assets first, then manifests/data, then pages. Retain old hashed assets for open tabs.
  for phase in assets data pages; do
    while IFS= read -r -d '' file; do
      case "$file" in
        *.html) [ "$phase" = pages ] || continue ;;
        *.json) [ "$phase" = data ] || continue ;;
        *) [ "$phase" = assets ] || continue ;;
      esac
      if ! atomic_file "$file" "$target_dir/${file#"$source_dir"/}"; then rm -f -- "$listing"; return 1; fi
    done < "$listing"
  done
  rm -f -- "$listing"
}

cleanup_release() {
  # Only clean the unique extraction directory under the resolved temporary root.
  if [[ -n "${CALYX_RUN_TMP:-}" && "$CALYX_RUN_TMP" == "$CALYX_RUN_TMP_ROOT"/calyx-deploy.* ]]; then rm -rf -- "$CALYX_RUN_TMP"; fi
  if [ "${CALYX_RUN_LOCK_OWNED:-0}" = 1 ]; then rm -f -- "$CALYX_RUN_LOCK_DIR/pid"; rmdir "$CALYX_RUN_LOCK_DIR" 2>/dev/null || true; fi
}

log_line() { local dir="$1"; shift; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$dir/log" 2>/dev/null || true; }

# Download only the files whose sha256 differs from the live copy (MANIFEST lists "hash  path" for site/).
# Every file is checked against the manifest before anything is installed, so a stale CDN copy fails safely
# and the next Cron run retries.
fetch_changed() {
  local base="$1" manifest="$2" destination="$3" out="$4" hash path target got count=0
  command -v sha256sum >/dev/null 2>&1 || return 1
  while read -r hash path; do
    [ -n "$hash" ] && [ -n "$path" ] || continue
    case "$path" in /*|*..*) return 1 ;; esac
    target="$destination/$path"
    if [ -f "$target" ]; then
      got=$(sha256sum < "$target") || return 1
      [ "${got%% *}" = "$hash" ] && continue
    fi
    mkdir -p "$(dirname "$out/$path")" || return 1
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -H 'Cache-Control: no-cache' "$base/site/$path" -o "$out/$path" || return 1
    got=$(sha256sum < "$out/$path") || return 1
    [ "${got%% *}" = "$hash" ] || return 1
    count=$((count + 1))
  done < "$manifest"
  printf '%s' "$count"
}

main() {
  # Canonical name: the old lower-case address served cached copies (pipeline/HANDOFF.md).
  local repo="saffarzad/Calyx-deploy"
  local base="https://raw.githubusercontent.com/$repo/main"
  local destination="${CALYX_DEPLOY_DEST:-$HOME/public_html}"
  local state="${CALYX_DEPLOY_STATE:-$HOME/.calyx-deploy}"
  local new source_dir='' release changed
  CALYX_RUN_TMP=''; CALYX_RUN_LOCK_DIR=''; CALYX_RUN_LOCK_OWNED=0
  mkdir -p "$state" "$destination"
  state=$(cd "$state" && pwd -P)
  destination=$(cd "$destination" && pwd -P)
  CALYX_RUN_TMP_ROOT="${CALYX_DEPLOY_TMP_ROOT:-${TMPDIR:-/tmp}}"
  mkdir -p "$CALYX_RUN_TMP_ROOT"
  CALYX_RUN_TMP_ROOT=$(cd "$CALYX_RUN_TMP_ROOT" && pwd -P)
  trap cleanup_release EXIT
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$state/lock"
    flock -n 9 || return 0
  else
    CALYX_RUN_LOCK_DIR="$state/running"
    if ! mkdir "$CALYX_RUN_LOCK_DIR" 2>/dev/null; then
      local old_pid
      old_pid=$(cat "$CALYX_RUN_LOCK_DIR/pid" 2>/dev/null || true)
      [ -n "$old_pid" ] || return 0
      if kill -0 "$old_pid" 2>/dev/null; then return 0; fi
      rm -f -- "$CALYX_RUN_LOCK_DIR/pid"
      rmdir "$CALYX_RUN_LOCK_DIR" 2>/dev/null || return 0
      mkdir "$CALYX_RUN_LOCK_DIR" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" > "$CALYX_RUN_LOCK_DIR/pid"
    CALYX_RUN_LOCK_OWNED=1
  fi
  new=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -H 'Cache-Control: no-cache' "$base/VERSION") || { log_line "$state" "version check failed"; return 0; }
  [ "$new" != "$(cat "$state/version" 2>/dev/null || true)" ] || return 0
  CALYX_RUN_TMP=$(mktemp -d "$CALYX_RUN_TMP_ROOT/calyx-deploy.XXXXXX")

  # 1) Incremental: only the changed files (a release is ~250MB, a typical update a few MB).
  if command -v sha256sum >/dev/null 2>&1 \
    && curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -H 'Cache-Control: no-cache' "$base/MANIFEST" -o "$CALYX_RUN_TMP/MANIFEST" 2>/dev/null \
    && [ -s "$CALYX_RUN_TMP/MANIFEST" ]; then
    mkdir -p "$CALYX_RUN_TMP/inc/site"
    # A failed or mismatched file leaves the live site untouched; the next run retries.
    changed=$(fetch_changed "$base" "$CALYX_RUN_TMP/MANIFEST" "$destination" "$CALYX_RUN_TMP/inc/site") || { log_line "$state" "incremental $new download failed"; return 1; }
    printf '%s\n' "$new" > "$CALYX_RUN_TMP/inc/VERSION"
    source_dir="$CALYX_RUN_TMP/inc/site"
    for f in index.html menu-demo/index.html menu-demo/data/demo.json; do
      [ -s "$source_dir/$f" ] || [ -s "$destination/$f" ] || { log_line "$state" "incremental $new incomplete"; return 1; }
    done
    publish_tree "$source_dir" "$destination" || { log_line "$state" "incremental $new install failed"; return 1; }
    atomic_file "$CALYX_RUN_TMP/inc/VERSION" "$state/version" || return 1
    log_line "$state" "deployed $(head -1 "$CALYX_RUN_TMP/inc/VERSION") ($changed files)"
    return 0
  fi
  log_line "$state" "no manifest for $new, downloading the full archive"

  # 2) Fallback: the whole archive.
  rm -rf -- "$CALYX_RUN_TMP/inc"
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 1500 "https://codeload.github.com/$repo/tar.gz/refs/heads/main" | tar -xz -C "$CALYX_RUN_TMP" || { log_line "$state" "archive download failed"; return 1; }
  for source_dir in "$CALYX_RUN_TMP"/*/site; do [ -d "$source_dir" ] && break; done
  release=$(dirname "$source_dir")
  [ -s "$source_dir/index.html" ] && [ -s "$source_dir/menu-demo/index.html" ] && [ -s "$source_dir/menu-demo/data/demo.json" ] && [ -s "$release/VERSION" ] || { log_line "$state" "archive incomplete"; return 1; }
  # Use the version inside this archive too, in case main advanced after the first request.
  new=$(cat "$release/VERSION")
  publish_tree "$source_dir" "$destination" || { log_line "$state" "archive install failed"; return 1; }
  atomic_file "$release/VERSION" "$state/version" || return 1
  log_line "$state" "deployed $(head -1 "$release/VERSION") (full archive)"
}

# Cron downloads this script into `bash` on stdin; BASH_SOURCE is unset in that mode.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
