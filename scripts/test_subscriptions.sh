#!/bin/bash
# Run real StoreKit Test transactions against a known working simulator runtime.
# Does not install runtimes, reset user devices, or enable production purchases.
set -euo pipefail

RECOCO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECOCO_TEST_OS="${RECOCO_STOREKIT_OS:-26.2}"
RECOCO_RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-${RECOCO_TEST_OS//./-}"
RECOCO_TEST_DEVICE_NAME="Recoco StoreKit ${RECOCO_TEST_OS}"
RECOCO_BUILD_PATH="${RECOCO_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/recoco-subscription-build}"
RECOCO_RESULT_PATH="${RECOCO_TEST_RESULT_PATH:-${TMPDIR:-/tmp}/recoco-subscriptions-$(date +%Y%m%d-%H%M%S).xcresult}"

if [[ "$RECOCO_TEST_OS" == "26.5" ]]; then
  echo "iOS 26.5 has a known StoreKit Test configuration failure (SKInternalErrorDomain Code=3)." >&2
  echo "Use iOS 26.2, or explicitly select another verified runtime with RECOCO_STOREKIT_OS." >&2
  exit 2
fi

RECOCO_RUNTIMES_JSON="$(xcrun simctl list runtimes --json)"
export RECOCO_RUNTIMES_JSON RECOCO_RUNTIME_ID
if ! python3 - <<'PY'
import json, os, sys
rows = json.loads(os.environ['RECOCO_RUNTIMES_JSON'])['runtimes']
sys.exit(0 if any(r['identifier'] == os.environ['RECOCO_RUNTIME_ID'] and r.get('isAvailable') for r in rows) else 1)
PY
then
  echo "Install the iOS ${RECOCO_TEST_OS} simulator runtime first:" >&2
  echo "xcodebuild -downloadPlatform iOS -buildVersion ${RECOCO_TEST_OS} -architectureVariant universal" >&2
  exit 2
fi

RECOCO_DEVICES_JSON="$(xcrun simctl list devices available --json)"
export RECOCO_DEVICES_JSON RECOCO_TEST_DEVICE_NAME
RECOCO_DEVICE_ID="$(python3 - <<'PY'
import json, os
devices = json.loads(os.environ['RECOCO_DEVICES_JSON'])['devices'].get(os.environ['RECOCO_RUNTIME_ID'], [])
matches = [d['udid'] for d in devices if d['name'] == os.environ['RECOCO_TEST_DEVICE_NAME']]
if len(matches) > 1:
    raise SystemExit('Duplicate Recoco test simulators. Resolve the duplicate name before testing.')
print(matches[0] if matches else '')
PY
)"
if [[ -z "$RECOCO_DEVICE_ID" ]]; then
  RECOCO_DEVICE_ID="$(xcrun simctl create "$RECOCO_TEST_DEVICE_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RECOCO_RUNTIME_ID")"
fi

echo "StoreKit tests: $RECOCO_TEST_DEVICE_NAME ($RECOCO_DEVICE_ID)"
echo "Results: $RECOCO_RESULT_PATH"
# xcodebuild owns launching the test destination; its state/data are retained.
xcodebuild test \
  -project "$RECOCO_ROOT/Recoco.xcodeproj" \
  -scheme RecocoSubscriptions \
  -destination "platform=iOS Simulator,id=$RECOCO_DEVICE_ID" \
  -derivedDataPath "$RECOCO_BUILD_PATH" \
  -resultBundlePath "$RECOCO_RESULT_PATH" \
  -parallel-testing-enabled NO \
  -only-testing:RecocoTests/SubscriptionTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
