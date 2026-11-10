#!/bin/bash
# Simulator check, run by .github/workflows/build.yml on a macOS runner.
#
# Builds ScrollGuard for the iOS Simulator, starts it a few times with different start pages and
# saves, for each start, a screenshot and the app's own diagnostics log into ./smoke/.
# It answers what a successful compile cannot: does the app start, does Instagram load in it,
# is the filter running, are Reels pages refused.
#
# It cannot answer anything about a signed-in account (nobody signs in here) or about installing
# on a real iPhone with SideStore.
set -o pipefail

BUNDLE_ID="${BUNDLE_ID:-io.github.tg-jorj-2005.scrollguard}"
OUT=smoke
mkdir -p "$OUT"

# An iPhone of the newest iOS runtime, a plain model if there is one.
read -r UDID DEVICE_NAME < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        name = device["name"]
        if not name.startswith("iPhone"):
            continue
        plain = name.startswith("iPhone 1") and "Pro" not in name and "Plus" not in name
        key = (runtime, plain, name)
        if best is None or key > best[0]:
            best = (key, device["udid"], name.replace(" ", "-") + "/" + runtime.split(".")[-1])
if best is None:
    sys.exit("no iPhone simulator available")
print(best[1], best[2])
')
if [ -z "$UDID" ]; then
  echo "::error::no iPhone simulator found"
  xcrun simctl list devices available
  exit 1
fi
echo "Simulator: $DEVICE_NAME ($UDID)"

set -e
xcodebuild build -project ScrollGuard.xcodeproj -scheme ScrollGuard -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/sim \
  > "$OUT/build-sim.log" 2>&1 || { grep -E "error:|fatal error" "$OUT/build-sim.log" | sort -u | head -60; tail -30 "$OUT/build-sim.log"; exit 1; }
APP=build/sim/Build/Products/Debug-iphonesimulator/ScrollGuard.app
test -d "$APP"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl install "$UDID" "$APP"
set +e

FAILED=0

# run <name> <seconds to wait> [launch arguments...]
run() {
  local name="$1" wait="$2"
  shift 2
  echo "::group::$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" ${@+"$@"}
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" > /dev/null 2>&1
  # The list is read whole before it is searched. Piped straight into `grep -q`, grep leaves at
  # the first match, the listing dies of a broken pipe, and with pipefail that counted as
  # "not running" although the app had just been found.
  local services
  services=$(xcrun simctl spawn "$UDID" launchctl list 2> /dev/null)
  if grep -q "$BUNDLE_ID" <<< "$services"; then
    echo "state: running"
  else
    echo "::error::$name: the app is not running any more (it crashed or exited)"
    FAILED=1
  fi
  local data
  data=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2> /dev/null)
  if [ -f "$data/Library/Caches/scrollguard-log.txt" ]; then
    cp "$data/Library/Caches/scrollguard-log.txt" "$OUT/$name.log"
    cat "$OUT/$name.log"
  else
    echo "::error::$name: the app wrote no log"
    FAILED=1
  fi
  echo "::endgroup::"
}

# expect <name> <text that must be in that start's log> <what it means>
expect() {
  if grep -qF -- "$2" "$OUT/$1.log" 2> /dev/null; then
    echo "ok    $1: $3"
  else
    echo "::error::$1: $3 — '$2' is not in the log"
    FAILED=1
  fi
}

LOGIN="https://www.instagram.com/accounts/login/"

run 1-home 25
run 2-login 25 -debugStartURL "$LOGIN"
# The same page with no filter installed at all: if it differs, the filter is at fault.
run 3-login-plain 25 -debugStartURL "$LOGIN" -debugNoFilter YES
run 4-reels 20 -debugStartURL "https://www.instagram.com/reels/"
run 5-panel 12 -debugShowPanel YES
# Right after a start: the label with the build's version is on screen for a few seconds.
run 6-launch 2

echo "Checks:"
expect 1-home "[page] commit www.instagram.com" "Instagram loaded in the web view"
expect 1-home "[nav] allow www.instagram.com" "the navigation rules are consulted"
expect 1-home "[filter] running on" "the filter script runs in the page"
expect 2-login "[filter] running on /accounts/login" "the filter script runs on the sign-in page"
expect 4-reels "[block] load /reels" "a direct load of the Reels viewer is refused"
expect 4-reels "[nav] allow www.instagram.com/" "after the refusal the feed is opened instead"

# Crash reports written by the simulator during this run, if any.
find ~/Library/Logs/DiagnosticReports -name 'ScrollGuard*' -newer "$OUT/build-sim.log" -print0 2> /dev/null |
  while IFS= read -r -d '' report; do
    echo "::error::crash report: $(basename "$report")"
    cp "$report" "$OUT/"
    head -60 "$report"
  done

exit "$FAILED"
