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
  local source_dir="$1" target_dir="$2" file phase
  # Assets first, then manifests/data, then pages. Retain old hashed assets for open tabs.
  for phase in assets data pages; do
    while IFS= read -r -d '' file; do
      case "$file" in
        *.html) [ "$phase" = pages ] || continue ;;
        *.json) [ "$phase" = data ] || continue ;;
        *) [ "$phase" = assets ] || continue ;;
      esac
      atomic_file "$file" "$target_dir/${file#"$source_dir"/}" || return 1
    done < <(find "$source_dir" -type f -print0)
  done
}

cleanup_release() {
  # Only clean the unique extraction directory under the resolved temporary root.
  if [[ -n "${CALYX_RUN_TMP:-}" && "$CALYX_RUN_TMP" == "$CALYX_RUN_TMP_ROOT"/calyx-deploy.* ]]; then rm -rf -- "$CALYX_RUN_TMP"; fi
  if [ "${CALYX_RUN_LOCK_OWNED:-0}" = 1 ]; then rm -f -- "$CALYX_RUN_LOCK_DIR/pid"; rmdir "$CALYX_RUN_LOCK_DIR" 2>/dev/null || true; fi
}

main() {
  local repo="saffarzad/calyx-deploy"
  local destination="${CALYX_DEPLOY_DEST:-$HOME/public_html}"
  local state="${CALYX_DEPLOY_STATE:-$HOME/.calyx-deploy}"
  local new source_dir='' release
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
  new=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "https://raw.githubusercontent.com/$repo/main/VERSION") || return 0
  [ "$new" != "$(cat "$state/version" 2>/dev/null || true)" ] || return 0
  CALYX_RUN_TMP=$(mktemp -d "$CALYX_RUN_TMP_ROOT/calyx-deploy.XXXXXX")
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "https://codeload.github.com/$repo/tar.gz/refs/heads/main" | tar -xz -C "$CALYX_RUN_TMP" || return 1
  for source_dir in "$CALYX_RUN_TMP"/*/site; do [ -d "$source_dir" ] && break; done
  release=$(dirname "$source_dir")
  [ -s "$source_dir/index.html" ] && [ -s "$source_dir/menu-demo/index.html" ] && [ -s "$source_dir/menu-demo/data/demo.json" ] && [ -s "$release/VERSION" ] || return 1
  # Use the version inside this archive too, in case main advanced after the first request.
  new=$(cat "$release/VERSION")
  publish_tree "$source_dir" "$destination" || return 1
  atomic_file "$release/VERSION" "$state/version" || return 1
  printf '%s deployed %s\n' "$(date '+%F %T')" "$new" >> "$state/log"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
