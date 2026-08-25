#!/usr/bin/env bash
# Check every stream in catalog.json is actually playable.
#
# Run before committing a catalog change, and periodically afterwards — streams
# die silently and the app has no way to tell you.
#
#   bash check-streams.sh
#
# TWO THINGS THIS GETS RIGHT, both learned the hard way:
#
# 1. It follows a VARIANT playlist, not just the master. A dead feed can serve a
#    stale HTTP 200 master from a CDN edge while every variant behind it 404s —
#    that is how four dead channels sat unnoticed in this catalogue.
#
# 2. It checks URLs, not name/URL pairs. An earlier version pasted the list of
#    names against the list of streamUrls positionally. That silently misaligned
#    the moment a scheduled channel (which has no streamUrl, only a schedule of
#    item urls) entered the file, so every row reported the wrong channel's
#    result and one channel vanished from the output entirely. Without jq there
#    is no safe way to pair them in shell, so it does not try.

set -u
CATALOG="$(dirname "$0")/catalog.json"
UA="Mozilla/5.0"
fail=0

# Every playable address in the file: direct streams and scheduled-item files.
grep -oE '"(streamUrl|url)"[[:space:]]*:[[:space:]]*"[^"]*"' "$CATALOG" \
  | sed -E 's/.*"([^"]*)"$/\1/' \
  | sed -e "s/[\]u0027/'/g" -e 's/[\]u0026/\&/g' -e 's|[\]/|/|g' \
  | grep -E '^https?://' | sort -u > /tmp/_catalog_urls

total=$(wc -l < /tmp/_catalog_urls)
echo "checking $total addresses"

while read -r url; do
  label=$(basename "${url%%\?*}" | cut -c1-46)

  # Progressive files (mp4 etc.) just need to be fetchable.
  if ! printf '%s' "$url" | grep -q '\.m3u8'; then
    code=$(curl -sS -o /dev/null -L --max-time 30 -r 0-1023 -A "$UA" -w '%{http_code}' "$url" 2>/dev/null)
    case "$code" in
      200|206) printf 'OK    %s\n' "$label" ;;
      *) printf 'DEAD  %-46s HTTP %s\n' "$label" "$code"; fail=1 ;;
    esac
    continue
  fi

  body=$(curl -sS --max-time 25 -A "$UA" "$url" 2>/dev/null)
  if ! printf '%s' "$body" | head -1 | grep -q '#EXTM3U'; then
    printf 'DEAD  %-46s master is not a manifest\n' "$label"; fail=1; continue
  fi

  variant=$(printf '%s' "$body" | grep -v '^#' | grep -m1 '\.m3u8')
  if [ -z "$variant" ]; then
    printf 'OK    %-46s (single media playlist)\n' "$label"; continue
  fi
  case "$variant" in
    http*) vurl="$variant" ;;
    /*)    vurl="$(printf '%s' "$url" | sed -E 's#(https?://[^/]+).*#\1#')$variant" ;;
    *)     vurl="$(dirname "$url")/$variant" ;;
  esac

  code=$(curl -sS -o /tmp/_variant.m3u8 -w '%{http_code}' --max-time 25 -A "$UA" "$vurl" 2>/dev/null)
  if [ "$code" = "200" ] && head -1 /tmp/_variant.m3u8 | grep -q '#EXTM3U'; then
    printf 'OK    %-46s (%s segments)\n' "$label" "$(grep -c '\.ts\|\.m4s' /tmp/_variant.m3u8)"
  else
    printf 'DEAD  %-46s variant HTTP %s\n' "$label" "$code"; fail=1
  fi
done < /tmp/_catalog_urls

exit $fail
