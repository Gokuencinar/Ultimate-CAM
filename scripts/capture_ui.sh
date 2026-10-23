#!/bin/bash
set -euo pipefail
mkdir -p build/ui
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build > build/ui/simulator-build.log 2>&1
runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]; assert r, "No iOS runtime"; print(sorted(r,key=lambda r: tuple(int(v) for v in r["version"].split(".")),reverse=True)[0]["identifier"])')
device=$(xcrun simctl create Ultimate-CAM-UI com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro "$runtime")
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl install "$device" build/Simulator/Build/Products/Debug-iphonesimulator/UltimateCAM.app
xcrun simctl privacy "$device" grant camera com.gokuencinar.ultimatecam
xcrun simctl launch "$device" com.gokuencinar.ultimatecam
sleep 3
xcrun simctl io "$device" screenshot build/ui/Ultimate-CAM-photo.png
xcrun simctl terminate "$device" com.gokuencinar.ultimatecam
xcrun simctl launch "$device" com.gokuencinar.ultimatecam -show-controls -stack-mode
sleep 2
xcrun simctl io "$device" screenshot build/ui/Ultimate-CAM-controls.png
xcrun simctl terminate "$device" com.gokuencinar.ultimatecam
xcrun simctl launch "$device" com.gokuencinar.ultimatecam -show-controls -processing-controls
sleep 2
xcrun simctl io "$device" screenshot build/ui/Ultimate-CAM-processing.png
xcrun simctl terminate "$device" com.gokuencinar.ultimatecam
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM-UI \
  -configuration Debug -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath build/Simulator -parallel-testing-enabled NO \
  -resultBundlePath build/ui/Interaction.xcresult \
  CODE_SIGNING_ALLOWED=NO test > build/ui/interaction-tests.log 2>&1
container=$(xcrun simctl get_app_container "$device" com.gokuencinar.ultimatecam data)
cp "$container/Library/Caches/UltimateCAM-capture.jsonl" build/ui/UI-interaction-trace.jsonl
python3 - <<'PY'
import json, pathlib
rows = [json.loads(s) for s in pathlib.Path('build/ui/UI-interaction-trace.jsonl').read_text().splitlines()]
events = {r['event'] for r in rows}
assert {'ui.focus.tap', 'ui.focus.longPress'} <= events, 'Viewfinder touches did not reach UIKit'
print('UI touch routing and settings interaction passed; simulator only, not optical focus.')
PY
printf '%s\n' 'Simulator UI only; no camera capture or photo quality validation.' > build/ui/README.txt
