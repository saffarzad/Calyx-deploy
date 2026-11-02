#!/bin/bash
# روی هاست سی‌پنل با Cron Job اجرا می‌شود: اگر نسخهٔ تازه‌ای در مخزن عمومی calyx-deploy باشد،
# آن را دانلود و روی public_html می‌گذارد. هاست فقط به گیت‌هاب وصل می‌شود؛ هیچ رمزی لازم نیست.
set -e
REPO="saffarzad/calyx-deploy"
DEST="$HOME/public_html"
STATE="$HOME/.calyx-deploy"
mkdir -p "$STATE"
NEW=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/VERSION") || exit 0
[ "$NEW" = "$(cat "$STATE/version" 2>/dev/null)" ] && exit 0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" | tar -xz -C "$TMP"
SRC="$TMP/calyx-deploy-main/site"
[ -f "$SRC/index.html" ] || exit 1
# پوشه‌هایی که فایل‌های هش‌دار دارند کامل جایگزین می‌شوند تا فایل‌های کهنه جمع نشوند
rm -rf "$DEST/_astro" "$DEST/menu-demo"
cp -a "$SRC/." "$DEST/"
echo "$NEW" > "$STATE/version"
echo "$(date '+%F %T') deployed $NEW" >> "$STATE/log"
