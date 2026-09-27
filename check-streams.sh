#!/usr/bin/env bash
# Check that the stream addresses in catalog.json actually play.
#
#   bash check-streams.sh                       every address in catalog.json
#                                               (the weekly sweep; run it
#                                               yourself before publishing)
#   bash check-streams.sh --new-since BASE      only the addresses that are NOT
#                                               in BASE, another catalog.json:
#                                               what a pull request adds
#
# Options:
#   --catalog FILE   check FILE instead of the catalog.json beside this script
#   --timeout S      seconds allowed for each request (default 30)
#   --retries N      before calling an address dead, try it N more times,
#                    2 seconds apart (default 0)
#   --jobs N         how many addresses to try at the same time (default 1)
#   --time-limit S   start no new address once S seconds have passed; the rest
#                    are reported as SKIP, not tried (default 0: no limit).
#                    Addresses already started are finished, so a run can
#                    overrun S by about 2 x timeout x (retries + 1).
#   --checked-by-hand
#                    still try and report every address, but let the run pass
#                    when some did not play or were not tried: a person has
#                    checked them. The pull-request check adds this when the
#                    description says "streams checked by hand". It never
#                    passes a run that went wrong (status 2).
#
# Exit status: 0 every address played (or --checked-by-hand accepted the
# rest), 1 at least one did not, 2 the check itself went wrong, 3 none was
# dead but the time limit left some untried, 64 the command was typed wrong.
#
# Every result line starts with OK, DEAD or SKIP, then the file's name, then
# what happened. A DEAD line ends with [host ...]: the server that failed. The
# summary counts dead addresses per host, because when a whole host is down or
# slow, the host is the thing to fix (or to re-host from). The weekly workflow
# counts lines starting with DEAD, so nothing else may start with that word.
#
# The pull-request check (.github/workflows/validate.yml) runs
#   --new-since <main's catalog.json> --timeout 60 --retries 1 --jobs 4
#   --time-limit 1500
# and tools/network_checks_selftest.dart proves, on every pull request, that
# this script still tells a dead address from a live one.
#
# THREE THINGS THIS GETS RIGHT, all learned the hard way:
#
# 1. It follows a VARIANT playlist, not just the master. A dead feed can serve a
#    stale HTTP 200 master from a CDN edge while every variant behind it 404s -
#    that is how four dead channels sat unnoticed in this catalogue.
#
# 2. It checks URLs, not name/URL pairs. An earlier version pasted the list of
#    names against the list of streamUrls positionally. That silently misaligned
#    the moment a scheduled channel (which has no streamUrl, only a schedule of
#    item urls) entered the file, so every row reported the wrong channel's
#    result and one channel vanished from the output entirely. Without jq there
#    is no safe way to pair them in shell, so it does not try.
#
# 3. It says WHY an address failed (HTTP 404, host not found, no answer in
#    time) and which host it was. "DEAD" alone cannot tell a deleted file from
#    a slow host: one host measured on 2026-09-19 took 12-20 s just to open
#    each connection, 9 of its 114 files timed out, and 3 of those played when
#    tried again.
#
# And one thing players do that it copies: a live address may REDIRECT (a
# tokenised CDN entry point usually does), and the picture playlist is then
# looked for next to where the address ended up - on that host, without the
# first address's query - not where it started.

set -u

CATALOG="$(dirname "$0")/catalog.json"
BASE=""
TIMEOUT=30
RETRIES=0
JOBS=1
TIME_LIMIT=0
BY_HAND=0

usage() {
  echo "usage: bash check-streams.sh [--catalog FILE] [--new-since BASE.json]" \
       "[--timeout S] [--retries N] [--jobs N] [--time-limit S]" \
       "[--checked-by-hand]" >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --catalog)    [ $# -ge 2 ] || usage; CATALOG=$2; shift 2 ;;
    --new-since)  [ $# -ge 2 ] || usage; BASE=$2; shift 2 ;;
    --timeout)    [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --retries)    [ $# -ge 2 ] || usage; RETRIES=$2; shift 2 ;;
    --jobs)       [ $# -ge 2 ] || usage; JOBS=$2; shift 2 ;;
    --time-limit) [ $# -ge 2 ] || usage; TIME_LIMIT=$2; shift 2 ;;
    --checked-by-hand) BY_HAND=1; shift ;;
    *) usage ;;
  esac
done
for n in "$TIMEOUT" "$RETRIES" "$JOBS" "$TIME_LIMIT"; do
  case "$n" in ''|*[!0-9]*) usage ;; esac
done
{ [ "$TIMEOUT" -ge 1 ] && [ "$JOBS" -ge 1 ]; } || usage
# A mistyped base must not quietly count as "no base", which would make every
# address "new" - or, worse, a missing catalogue count as "nothing to check".
for f in "$CATALOG" ${BASE:+"$BASE"}; do
  [ -r "$f" ] || { echo "No such file: $f" >&2; exit 64; }
done

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
UA="Mozilla/5.0"
export TIMEOUT RETRIES UA WORK TIME_LIMIT

# Every playable address in a catalogue file: direct streams and
# scheduled-item files, once each, in a fixed order.
addresses() {
  grep -oE '"(streamUrl|url)"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" \
    | sed -E 's/.*"([^"]*)"$/\1/' \
    | sed -e "s/[\]u0027/'/g" -e 's/[\]u0026/\&/g' -e 's|[\]/|/|g' \
    | grep -E '^https?://' | LC_ALL=C sort -u
}

addresses "$CATALOG" > "$WORK/all"
all=$(wc -l < "$WORK/all" | tr -d ' ')
if [ -n "$BASE" ]; then
  addresses "$BASE" > "$WORK/base"
  LC_ALL=C comm -23 "$WORK/all" "$WORK/base" > "$WORK/urls"
  total=$(wc -l < "$WORK/urls" | tr -d ' ')
  echo "checking $total new address(es); the other $((all - total)) are" \
       "already in $(basename "$BASE") and are not re-checked"
else
  cp "$WORK/all" "$WORK/urls"
  total=$all
  echo "checking $total addresses"
fi
if [ "$total" -eq 0 ]; then
  echo "Nothing new to check."
  exit 0
fi

# Why curl gave up, in words, from its exit status.
curl_reason() {
  case "$1" in
    6)     echo "host not found" ;;
    7)     echo "connection refused" ;;
    28)    echo "no answer within ${TIMEOUT} s" ;;
    35|60) echo "secure connection (TLS) failed" ;;
    *)     echo "download failed (curl error $1)" ;;
  esac
}

# One attempt at one address. Prints what happened; succeeds if it plays.
probe_once() {
  local url=$1 tmp=$2 code rc out here variant vurl

  # Progressive files (mp4 etc.) just need to be fetchable.
  if ! printf '%s' "$url" | grep -q '\.m3u8'; then
    code=$(curl -sS -o /dev/null -L --max-time "$TIMEOUT" -r 0-1023 -A "$UA" \
             -w '%{http_code}' "$url" 2>/dev/null)
    rc=$?
    case "$code" in
      200|206) echo "(HTTP $code)"; return 0 ;;
    esac
    if [ "$code" = "000" ]; then curl_reason "$rc"; else echo "HTTP $code"; fi
    return 1
  fi

  # -L: follow a redirect, as players do. %{url_effective} is where the
  # playlist was finally found, which is what its own addresses are relative
  # to.
  rm -f "$tmp.master" "$tmp.variant"
  out=$(curl -sS -L -o "$tmp.master" -w '%{http_code} %{url_effective}' \
          --max-time "$TIMEOUT" -A "$UA" "$url" 2>/dev/null)
  rc=$?
  code=${out%% *}
  case "$out" in *' '*) here=${out#* } ;; *) here=$url ;; esac
  case "$code" in
    2??) ;;
    000|'') curl_reason "$rc"; return 1 ;;
    *) echo "HTTP $code"; return 1 ;;
  esac
  if ! head -1 "$tmp.master" 2>/dev/null | grep -q '#EXTM3U'; then
    if [ "$rc" -ne 0 ]; then curl_reason "$rc"; else echo "master is not a manifest"; fi
    return 1
  fi

  # tr: a playlist may have Windows line endings. Players ignore the CR; left
  # in, it would end up inside the address and curl would refuse it.
  variant=$(grep -v '^#' "$tmp.master" | tr -d '\r' | grep -m1 '\.m3u8')
  if [ -z "$variant" ]; then
    echo "(single media playlist)"
    return 0
  fi
  # A query belongs to the playlist's own address, not to its neighbours
  # (and a token in it can contain "/", which would move the folder).
  here=${here%%\?*}
  case "$variant" in
    http*) vurl="$variant" ;;
    /*)    vurl="$(printf '%s' "$here" | sed -E 's#(https?://[^/]+).*#\1#')$variant" ;;
    *)     vurl="$(dirname "$here")/$variant" ;;
  esac

  code=$(curl -sS -L -o "$tmp.variant" -w '%{http_code}' --max-time "$TIMEOUT" \
           -A "$UA" "$vurl" 2>/dev/null)
  rc=$?
  if [ "$code" = "200" ] && head -1 "$tmp.variant" 2>/dev/null | grep -q '#EXTM3U'; then
    echo "($(grep -c '\.ts\|\.m4s' "$tmp.variant") segments)"
    return 0
  fi
  if [ "$code" = "000" ]; then echo "variant: $(curl_reason "$rc")"; else echo "variant HTTP $code"; fi
  return 1
}

# probe INDEX URL - tries one address, with retries, and prints its result
# line. A copy of the line goes to $WORK so the summary can be built once
# every job has finished (jobs run side by side, so nothing else is shared).
probe() {
  local index=$1 url=$2 label host detail first="" try=1 line
  # For tools/network_checks_selftest.dart ONLY: pretend the probe of address
  # number N crashed, to prove that a run which loses a result is never read
  # as a pass. Nothing else sets this variable.
  [ "${CHECK_STREAMS_SELFTEST_CRASH_AT:-}" = "$index" ] && exit 255
  label=$(basename "${url%%\?*}" | cut -c1-46)
  host=$(printf '%s' "$url" | sed -E 's#^[A-Za-z]+://([^/?#]*).*#\1#; s#.*@##; s#:[0-9]*$##')
  if [ "$TIME_LIMIT" -gt 0 ] && [ $(( $(date +%s) - START )) -ge "$TIME_LIMIT" ]; then
    line=$(printf 'SKIP  %-46s not tried: the %s s time limit ran out' \
             "$label" "$TIME_LIMIT")
  else
    while :; do
      if detail=$(probe_once "$url" "$WORK/playlist.$index"); then
        [ "$try" -gt 1 ] && detail="$detail - played on try $try, after: $first"
        line=$(printf 'OK    %-46s %s' "$label" "$detail")
        break
      fi
      [ -z "$first" ] && first=$detail
      if [ "$try" -gt "$RETRIES" ]; then
        [ "$try" -gt 1 ] && detail="$detail (tried $try times)"
        line=$(printf 'DEAD  %-46s %s  [host %s]' "$label" "$detail" "$host")
        break
      fi
      try=$((try + 1))
      sleep 2
    done
  fi
  printf '%s\n' "$line" | tee "$WORK/result.$(printf '%06d' "$index")"
  case "$line" in DEAD*) return 1 ;; esac
  return 0
}
export -f curl_reason probe_once probe

# Numbered, NUL-separated, so an address can never be split or re-quoted on
# its way through xargs.
START=$(date +%s)
export START
i=0
while IFS= read -r url; do
  i=$((i + 1))
  printf '%d\0%s\0' "$i" "$url"
done < "$WORK/urls" | xargs -0 -n 2 -P "$JOBS" bash -c 'probe "$1" "$2"' _

checked=$(find "$WORK" -name 'result.*' | wc -l | tr -d ' ')
if [ "$checked" -ne "$total" ]; then
  echo
  echo "The check itself went wrong: only $checked of $total addresses got a" \
       "result. Nothing can be concluded from this run."
  exit 2
fi

cat "$WORK"/result.* > "$WORK/results"
dead=$(grep -c '^DEAD' "$WORK/results")
skipped=$(grep -c '^SKIP' "$WORK/results")
echo
if [ "$dead" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "All $total address(es) played."
  exit 0
fi
status=3
if [ "$dead" -gt 0 ]; then
  status=1
  echo "$dead of $total address(es) did not play. Dead addresses by host:"
  sed -n -E 's/^DEAD.*\[host ([^]]*)\]$/\1/p' "$WORK/results" \
    | LC_ALL=C sort | uniq -c | sort -rn \
    | while read -r n h; do printf '  %-40s %s dead\n' "$h" "$n"; done
fi
if [ "$skipped" -gt 0 ]; then
  echo "$skipped of $total address(es) were not tried: the $TIME_LIMIT s time" \
       "limit ran out first, so nothing is known about them."
fi
if [ "$BY_HAND" -eq 1 ]; then
  echo
  echo "ACCEPTED: a person says these addresses were checked by hand" \
       "(--checked-by-hand), so this run passes. Any of them that really is" \
       "dead will show viewers a spinner."
  exit 0
fi
exit "$status"
