#!/usr/bin/env bash
# Regenerate this app's framed App Store screenshots. Shared by every app; app details live in slots.json.
#
#   scripts/store-screenshots/generate.sh               clean build, capture (Simulator, or this Mac for "platform": "macos"), frame
#   scripts/store-screenshots/generate.sh --frame-only  re-frame the latest capture (caption/style edits)
#   --allow-dirty   capture even with uncommitted app/harness changes (drafts only)
#   --allow-older   capture code older than the version live on the App Store
#
# <screenshots_root>/<locale> is the only folder this writes and the only one upload lanes read.
# The provenance file records the commit, version and checksums; upload lanes verify it.
# Never uploads. Upload stays a separate, approved step.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$ROOT/build/store-screenshots"
export PYTHONDONTWRITEBYTECODE=1
# cfg app.scheme -> value from slots.json ("" for null).
cfg() { python3 -c "
import json, sys
value = json.load(open('$HERE/slots.json'))
for key in sys.argv[1].split('.'): value = value[key]
print('' if value is None else value)" "$1"; }
source_field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$RUN/source.json" "$1"; }
LOCALE="$(cfg locale)"
SCREENSHOTS_REL="$(cfg screenshots_root)/$LOCALE"
DEST="$ROOT/$SCREENSHOTS_REL"
PROVENANCE="$ROOT/$(cfg provenance)"

FRAME_ONLY=0
SOURCE_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --frame-only) FRAME_ONLY=1 ;;
    --allow-dirty|--allow-older) SOURCE_FLAGS+=("$arg") ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( FRAME_ONLY )); then
  RUN="$(ls -d "$WORK"/run-* 2>/dev/null | sort | tail -1)"
  [[ -n "$RUN" && -f "$RUN/raw/manifest.json" && -f "$RUN/source.json" ]] \
    || { echo "No earlier checked capture in $WORK; run without --frame-only first." >&2; exit 1; }
  echo "Re-framing $(basename "$RUN"): $(source_field version) ($(source_field build)) @ $(source_field commit | cut -c1-7)"
else
  RUN="$WORK/run-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$RUN/raw"
  # 1-2. Which code is this? Stops on uncommitted app/harness changes or code older than the App Store.
  python3 "$HERE/provenance.py" source "$RUN" ${SOURCE_FLAGS[@]+"${SOURCE_FLAGS[@]}"}
  VERSION="$(source_field version)"
  BUILD="$(source_field build)"
  CONFIGURATION="$(cfg app.configuration)"
  # Extra xcodebuild arguments: app.xcodebuild_args, a list of strings (missing means none).
  XCODEBUILD_ARGS=()
  python3 -c "
import json, sys
args = json.load(open('$HERE/slots.json'))['app'].get('xcodebuild_args', [])
if not (isinstance(args, list) and all(isinstance(arg, str) for arg in args)):
    sys.exit('slots.json app.xcodebuild_args must be a list of strings')"
  while IFS= read -r -d '' arg; do XCODEBUILD_ARGS+=("$arg"); done < <(python3 -c "
import json, sys
sys.stdout.write(''.join(arg + '\\0' for arg in json.load(open('$HERE/slots.json'))['app'].get('xcodebuild_args', [])))")

  PLATFORM="$(python3 -c "import json; print(json.load(open('$HERE/slots.json')).get('platform', 'ios'))")"
  if [[ "$PLATFORM" == "macos" ]]; then
    # Mac apps run on this Mac. The app's screenshot mode owns its appearance, window size and demo data,
    # and must not read or write san's real settings (see the skill's references/adopting.md).
    DESTINATION="platform=macOS"
    PRODUCTS="$CONFIGURATION"
    python3 -c "import json,sys; json.dump(dict(platform='macos', macos=sys.argv[1], xcode=sys.argv[2], configuration=sys.argv[3], appearance=sys.argv[4]), open(sys.argv[5], 'w'), indent=2)" \
      "$(sw_vers -productVersion)" "$(xcodebuild -version | head -1)" "$CONFIGURATION" "$(cfg appearance)" "$RUN/capture.json"
    echo "Capturing on macOS $(sw_vers -productVersion) ($CONFIGURATION) into $RUN"
  else
    SIMULATOR="$(cfg simulator)"
    read -r UDID RUNTIME < <(xcrun simctl list devices available -j | python3 -c "
import json, sys
name = sys.argv[1]
devices = [(d['udid'], runtime.rsplit('.', 1)[-1]) for runtime, ds in json.load(sys.stdin)['devices'].items()
           if 'iOS' in runtime for d in ds if d['name'] == name]
print(*devices[-1] if devices else ('', ''))" "$SIMULATOR")
    [[ -n "$UDID" ]] || { echo "Simulator '$SIMULATOR' not found; create it in Xcode or change slots.json." >&2; exit 1; }
    python3 -c "import json,sys; json.dump(dict(simulator=sys.argv[1], simulator_udid=sys.argv[2], runtime=sys.argv[3], xcode=sys.argv[4], configuration=sys.argv[5], appearance=sys.argv[6]), open(sys.argv[7], 'w'), indent=2)" \
      "$SIMULATOR" "$UDID" "$RUNTIME" "$(xcodebuild -version | head -1)" "$CONFIGURATION" "$(cfg appearance)" "$RUN/capture.json"

    echo "Capturing on $SIMULATOR ($RUNTIME, $CONFIGURATION) into $RUN"
    xcrun simctl boot "$UDID" 2> /dev/null || true
    xcrun simctl bootstatus "$UDID" > /dev/null
    # 3. No leftovers: remove the app (and its saved settings) before a clean build.
    xcrun simctl uninstall "$UDID" "$(cfg app.simulator_bundle_id)" 2> /dev/null || true
    # Screens that show the status bar get Apple's marketing defaults; appearance comes from slots.json.
    xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    PREVIOUS_APPEARANCE="$(xcrun simctl ui "$UDID" appearance)"
    xcrun simctl ui "$UDID" appearance "$(cfg appearance)"
    trap 'xcrun simctl status_bar "$UDID" clear; xcrun simctl ui "$UDID" appearance "$PREVIOUS_APPEARANCE"' EXIT
    DESTINATION="platform=iOS Simulator,id=$UDID"
    PRODUCTS="$CONFIGURATION-iphonesimulator"
  fi
  SPEC="$(cfg app.xcodegen_spec)"
  [[ -n "$SPEC" ]] && xcodegen generate --spec "$ROOT/$SPEC" --quiet
  # Stamped with the real project's version and build, so the test project's own values can't mislead.
  xcodebuild clean test \
    -project "$ROOT/$(cfg app.build_project)" -scheme "$(cfg app.scheme)" -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$WORK/DerivedData" -resultBundlePath "$RUN/result.xcresult" \
    -parallel-testing-enabled NO -only-testing:"$(cfg test)" ${XCODEBUILD_ARGS[@]+"${XCODEBUILD_ARGS[@]}"} \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" > "$RUN/xcodebuild.log" 2>&1 \
    || { tail -30 "$RUN/xcodebuild.log" >&2; echo "Capture test failed; full log: $RUN/xcodebuild.log" >&2; exit 1; }
  python3 "$HERE/provenance.py" built "$RUN" "$WORK/DerivedData/Build/Products/$PRODUCTS/$(cfg app.product).app"
  xcrun xcresulttool export attachments --path "$RUN/result.xcresult" --output-path "$RUN/raw" > /dev/null
fi

mkdir -p "$RUN/framed"
python3 "$HERE/frame.py" "$RUN/raw" "$RUN/framed"

# 5. What changed against the last approved (committed) set?
APPROVED="$RUN/approved"
mkdir -p "$APPROVED"
while IFS= read -r file; do
  git -C "$ROOT" show "HEAD:./$file" > "$APPROVED/$(basename "$file")"
done < <(git -C "$ROOT" ls-tree --name-only HEAD "$SCREENSHOTS_REL/" | grep '\.png$' || true)
python3 "$HERE/provenance.py" compare "$APPROVED" "$RUN/framed"

# 4. One folder: replace the deliver folder's PNGs so stale slots never upload. Old files go to the Trash.
mkdir -p "$DEST"
shopt -s nullglob
old=("$DEST"/*.png)
(( ${#old[@]} )) && trash "${old[@]}"
cp "$RUN/framed"/*.png "$DEST/"
python3 "$HERE/provenance.py" record "$RUN" "$DEST" "$PROVENANCE"
echo "Wrote $(ls "$DEST"/*.png | wc -l | tr -d ' ') screenshots to $DEST:"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$DEST"/*.png | paste - - - - | awk '{print "  " $1 "  " $3 "x" $5 "  alpha:" $7}' | sed "s|$DEST/||"
