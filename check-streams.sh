#!/usr/bin/env bash
# Check every stream in catalog.json is actually playable.
#
# Run this before committing a catalog change, and every so often afterwards —
# streams die silently and the app has no way to tell you.
#
#   bash check-streams.sh
#
# IMPORTANT: this follows a VARIANT playlist, not just the master. A dead feed
# can still serve a stale master playlist with HTTP 200 from a CDN edge while
# every variant behind it 404s. That is exactly how four dead channels sat
# unnoticed in this catalogue — checking only the master would have passed them.

set -u
CATALOG="$(dirname "$0")/catalog.json"
UA="Mozilla/5.0"
fail=0

# Pull "name" and "streamUrl" out of the catalogue without needing jq.
paste -d'\t' \
  <(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$CATALOG" | sed 's/.*"\([^"]*\)"$/\1/') \
  <(grep -o '"streamUrl"[[:space:]]*:[[:space:]]*"[^"]*"' "$CATALOG" | sed 's/.*"\([^"]*\)"$/\1/') |
while IFS=$'\t' read -r name url; do
  [ -z "$url" ] && continue
  body=$(curl -sS --max-time 20 -A "$UA" "$url" 2>/dev/null)
  if ! printf '%s' "$body" | head -1 | grep -q '#EXTM3U'; then
    printf 'DEAD  %-22s master is not a manifest\n' "$name"; fail=1; continue
  fi

  variant=$(printf '%s' "$body" | grep -v '^#' | grep -m1 '\.m3u8')
  if [ -z "$variant" ]; then
    printf 'OK    %-22s (single media playlist)\n' "$name"; continue
  fi

  case "$variant" in
    http*) vurl="$variant" ;;
    /*)    vurl="$(printf '%s' "$url" | sed -E 's#(https?://[^/]+).*#\1#')$variant" ;;
    *)     vurl="$(dirname "$url")/$variant" ;;
  esac

  code=$(curl -sS -o /tmp/_variant.m3u8 -w '%{http_code}' --max-time 20 -A "$UA" "$vurl" 2>/dev/null)
  if [ "$code" = "200" ] && head -1 /tmp/_variant.m3u8 | grep -q '#EXTM3U'; then
    segs=$(grep -c '\.ts\|\.m4s' /tmp/_variant.m3u8)
    printf 'OK    %-22s (%s segments)\n' "$name" "$segs"
  else
    printf 'DEAD  %-22s variant returned HTTP %s\n' "$name" "$code"; fail=1
  fi
done

exit $fail
