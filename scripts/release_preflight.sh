#!/usr/bin/env bash
# Static/environment preflight. Does not archive, sign, upload or prove membership.
set -u
set -o pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Recoco.xcodeproj/project.pbxproj"
SCHEME_FILE="$ROOT_DIR/Recoco.xcodeproj/xcshareddata/xcschemes/Recoco.xcscheme"
RUN_TESTS=false
WITH_AUTH=false
APPLE_ONLY=false
WITH_AI=false
TEAM_OVERRIDE=""
EXPECTED_VERSION="${RECOCO_RELEASE_VERSION:-1.0}"
EXPECTED_BUILD="${RECOCO_RELEASE_BUILD:-99}"
passes=0
warnings=0
failures=0
distribution_blockers=0
usage() {
  printf 'Usage: %s [--run-tests] [--team TEAM_ID] [--with-apple-auth|--with-auth] [--with-ai]\n' "$0"
  printf 'Default: local-only cleanup, subscriptions off. --with-ai includes authentication checks.\n'
  printf '%s\n' '--team validates an intended ID only; it does not configure signing or verify paid membership.'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-tests) RUN_TESTS=true; shift ;;
    --with-auth) WITH_AUTH=true; shift ;;
    --with-apple-auth) WITH_AUTH=true; APPLE_ONLY=true; shift ;;
    --with-ai) WITH_AUTH=true; WITH_AI=true; shift ;;
    --team)
      if [[ $# -lt 2 || ! "$2" =~ ^[A-Z0-9]{10}$ ]]; then usage >&2; exit 2; fi
      TEAM_OVERRIDE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
pass() { passes=$((passes + 1)); printf '[PASS] %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf '[WARN] %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf '[FAIL] %s\n' "$1"; }
block_distribution() { distribution_blockers=$((distribution_blockers + 1)); printf '[DISTRIBUTION BLOCKED] %s\n' "$1"; }
check_file() {
  if [[ -f "$ROOT_DIR/$1" ]]; then pass "$2"; else fail "$2 is missing: $1"; fi
}
printf 'Recoco Release Preflight — %s\n' "$([[ "$WITH_AUTH" == true ]] && printf 'optional account scope' || printf 'local-only cleanup')"
printf 'Project: %s\nExpected release: %s (%s)\n\n' "$ROOT_DIR" "$EXPECTED_VERSION" "$EXPECTED_BUILD"

macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
macos_remainder="${macos_version#*.}"
macos_minor="${macos_remainder%%.*}"
if [[ "$macos_major" =~ ^[0-9]+$ && "$macos_minor" =~ ^[0-9]+$ ]] &&
   { [[ "$macos_major" -gt 15 ]] || { [[ "$macos_major" -eq 15 && "$macos_minor" -ge 6 ]]; }; }; then
  pass "macOS $macos_version meets the Xcode 26 minimum"
else fail "macOS ${macos_version:-unknown} is below the required 15.6 minimum for Xcode 26"; fi
xcode_version_output="$(xcodebuild -version 2>/dev/null || true)"
xcode_version="$(printf '%s\n' "$xcode_version_output" | awk '/^Xcode / { print $2; exit }')"
xcode_major="${xcode_version%%.*}"
if [[ "$xcode_major" =~ ^[0-9]+$ && "$xcode_major" -ge 26 ]]; then
  pass "Xcode $xcode_version meets the configured upload minimum"
else fail "Full Xcode 26 or later is not available through xcodebuild"; fi
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" == *.app/Contents/Developer ]]; then pass "Full Xcode developer directory is selected";
else fail "Active developer directory is not full Xcode"; fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/recoco-release-preflight.XXXXXX")" || exit 2
trap 'rm -rf "$scratch"' EXIT
if ! plutil -convert json -o "$scratch/project.json" "$PROJECT_FILE" 2>/dev/null; then
  fail "Xcode project cannot be parsed"; exit 1
fi
# Inspect the Recoco target's Release configuration, never Debug/test targets.
if ! /usr/bin/python3 - "$scratch/project.json" "$scratch/release.json" <<'PY'
import json, pathlib, sys
objects = json.load(open(sys.argv[1]))["objects"]
targets = [o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("name") == "Recoco"]
if len(targets) != 1: raise SystemExit("Expected exactly one Recoco app target")
target = targets[0]
def release_config(owner):
    ids = objects[owner["buildConfigurationList"]]["buildConfigurations"]
    values = [objects[i] for i in ids if objects[i].get("name") == "Release"]
    if len(values) != 1: raise SystemExit("Expected exactly one Release configuration")
    return values[0]
owner = next(o for o in objects.values() if o.get("isa") == "PBXProject")
project_release, release = release_config(owner), release_config(target)
settings = dict(project_release.get("buildSettings", {}))
settings.update(release.get("buildSettings", {}))
resources = []
for phase_id in target.get("buildPhases", []):
    phase = objects[phase_id]
    if phase.get("isa") == "PBXResourcesBuildPhase":
        for build_id in phase.get("files", []):
            ref = objects.get(objects[build_id].get("fileRef"), {})
            resources.append(ref.get("path", ref.get("name", "")))
data = {
    "bundle": settings.get("PRODUCT_BUNDLE_IDENTIFIER", ""),
    "version": str(settings.get("MARKETING_VERSION", "")),
    "build": str(settings.get("CURRENT_PROJECT_VERSION", "")),
    "team": settings.get("DEVELOPMENT_TEAM", ""),
    "infoPath": settings.get("INFOPLIST_FILE", ""),
    "entitlementsPath": settings.get("CODE_SIGN_ENTITLEMENTS", ""),
    "hasBaseConfiguration": any("baseConfigurationReference" in c for c in (project_release, release)),
    "googleServiceBundled": any(pathlib.PurePosixPath(p).name == "GoogleService-Info.plist" for p in resources)
}
json.dump(data, open(sys.argv[2], "w"))
PY
then fail "Could not inspect the Recoco target Release settings"; exit 1; fi
read_value() {
  local value
  if value="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)"; then printf '%s' "$value"; fi
}
release_value() { read_value "$scratch/release.json" "$1"; }
pass "Recoco target Release configuration is readable"
bundle="$(release_value bundle)"
version="$(release_value version)"
build="$(release_value build)"
[[ "$bundle" == app.recoco.ios ]] && pass "Release Bundle ID is app.recoco.ios" || fail "Release Bundle ID must be app.recoco.ios"
[[ "$version" == "$EXPECTED_VERSION" ]] && pass "Release version is $version" || fail "Release marketing version does not match $EXPECTED_VERSION"
[[ "$build" == "$EXPECTED_BUILD" ]] && pass "Release build is $build" || fail "Release build number does not match $EXPECTED_BUILD"
team="${TEAM_OVERRIDE:-$(release_value team)}"
if [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  pass "Intended signing Team ID has a valid format$([[ -n "$TEAM_OVERRIDE" ]] && printf ' (command-line override only)')"
  warn "Paid Developer Program membership, distribution profiles and App Store Connect access remain unverified"
else
  block_distribution "Release Team is missing. Configure the paid distribution team or validate an intended ID with --team; a Personal Team install is not distribution validation"
fi
if [[ "$WITH_AUTH" == false && "$(release_value hasBaseConfiguration)" == true ]]; then
  fail "Local Release must be independent of the prototype/Debug xcconfig; base configuration found"
fi
info_path="$(release_value infoPath)"
entitlements_path="$(release_value entitlementsPath)"
if [[ "$WITH_AUTH" == false ]]; then
  [[ "$info_path" == Recoco/Info.Release.plist ]] && pass "Local Release uses Info.Release.plist" || fail "Local Release must use Recoco/Info.Release.plist"
  [[ "$entitlements_path" == Recoco/Recoco.Release.entitlements ]] && pass "Local Release uses its own entitlements" || fail "Local Release must use Recoco/Recoco.Release.entitlements"
fi
for relative_path in "$info_path" "$entitlements_path" Recoco/Resources/PrivacyInfo.xcprivacy ExportOptions.TestFlight.plist; do
  if [[ -n "$relative_path" && -f "$ROOT_DIR/$relative_path" ]] && plutil -lint "$ROOT_DIR/$relative_path" >/dev/null 2>&1; then pass "$relative_path is valid";
  else fail "Required Release property list is missing or invalid: $relative_path"; fi
done
info="$ROOT_DIR/$info_path"
entitlements="$ROOT_DIR/$entitlements_path"
if [[ "$WITH_AUTH" == false && "$(read_value "$info" RECOCO_APPLE_LOGIN_ENABLED)" == true ]]; then
  fail "Apple login requires --with-apple-auth preflight"
fi
[[ "$(read_value "$info" CFBundleShortVersionString)" == '$(MARKETING_VERSION)' ]] && pass "Archive version follows the Release setting" || fail "Release Info.plist must use MARKETING_VERSION"
[[ "$(read_value "$info" CFBundleVersion)" == '$(CURRENT_PROJECT_VERSION)' ]] && pass "Archive build follows the Release setting" || fail "Release Info.plist must use CURRENT_PROJECT_VERSION"
[[ "$(read_value "$info" RECOCO_SUBSCRIPTIONS_ENABLED)" == false ]] && pass "Subscriptions are disabled for this release" || fail "Subscriptions must be explicitly disabled for this release"
[[ -n "$(read_value "$info" NSPhotoLibraryUsageDescription)" ]] && pass "Photo permission purpose is present" || fail "Photo permission purpose is missing"
if [[ "$WITH_AUTH" == false ]]; then
  if plutil -extract CFBundleURLTypes json -o - "$info" >/dev/null 2>&1; then fail "Local Release must not include social sign-in callback schemes";
  else pass "Local Release has no social sign-in callback schemes"; fi
  if [[ "$(release_value googleServiceBundled)" == true ]]; then fail "Local Release packages GoogleService-Info.plist and could initialize optional account services";
  else pass "Local Release does not package Firebase account configuration"; fi
  if [[ "$(plutil -convert json -o - "$entitlements" 2>/dev/null | tr -d '[:space:]')" == '{}' ]]; then pass "Local Release has no account-only entitlements";
  else fail "Local Release entitlements must be empty for the current scope"; fi
  printf '[SCOPE] Firebase credentials, social sign-in and AI backend setup are not required for this local-only release.\n'
else
  google_service_file="$ROOT_DIR/GoogleService-Info.plist"
  check_file "GoogleService-Info.plist" "Production Firebase configuration"
  [[ "$(release_value googleServiceBundled)" == true ]] && pass "Firebase configuration is in the app resource phase" || fail "Firebase configuration is not in the app resource phase"
  [[ "$(read_value "$google_service_file" BUNDLE_ID)" == "$bundle" ]] && pass "Firebase Bundle ID matches Release" || fail "Firebase Bundle ID does not match Release"
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$entitlements" >/dev/null 2>&1; then pass "Sign in with Apple entitlement is present";
  else fail "Optional account release requires Sign in with Apple entitlement"; fi
  if [[ "$APPLE_ONLY" == true ]]; then
    [[ "$(read_value "$info" RECOCO_APPLE_LOGIN_ENABLED)" == true ]] && pass "Apple-only login is explicitly enabled" || fail "Apple-only login must be explicitly enabled"
    if plutil -extract CFBundleURLTypes json -o - "$info" >/dev/null 2>&1; then fail "Apple-only release must not include Google callback schemes";
    else pass "Native Apple login has no unused Google callback scheme"; fi
    printf '[MANUAL REQUIRED] Verify Firebase Apple provider, token revocation configuration and Apple capability before upload. Local files cannot prove server readiness.\n'
  else
    if plutil -extract CFBundleURLTypes json -o - "$info" >/dev/null 2>&1; then warn "Resolve and verify the Google callback scheme in the exact archive against REVERSED_CLIENT_ID";
    else fail "Optional account release requires a configured Google callback scheme"; fi
  fi
fi
package_resolved="$(find "$ROOT_DIR/Recoco.xcodeproj" -name Package.resolved -print -quit 2>/dev/null)"
[[ -n "$package_resolved" ]] && pass "Swift package versions are pinned" || fail "Package.resolved is missing"
if command -v xmllint >/dev/null 2>&1 && xmllint --noout "$SCHEME_FILE" >/dev/null 2>&1; then
  pass "Shared scheme XML is valid"
  archive_configuration="$(xmllint --xpath 'string(/Scheme/ArchiveAction/@buildConfiguration)' "$SCHEME_FILE" 2>/dev/null)"
  [[ "$archive_configuration" == Release ]] && pass "Shared scheme archives Release" || fail "Shared scheme must archive Release"
else fail "Shared scheme XML could not be validated"; fi
unit_test_count="$(grep -R -h -E 'func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(' "$ROOT_DIR/RecocoTests" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')"
ui_test_count="$(grep -R -h -E 'func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(' "$ROOT_DIR/RecocoUITests" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$unit_test_count" -gt 0 && "$ui_test_count" -gt 0 ]] && pass "$unit_test_count unit and $ui_test_count UI tests are defined (not executed by this check)" || fail "Unit or UI test definitions are missing"
for doc in PRIVACY_POLICY.md TERMS_OF_SERVICE.md APP_STORE_SUBMISSION.md TESTING.md; do check_file "$doc" "$doc source"; done
if find "$ROOT_DIR/Recoco/Resources/Assets.xcassets/AppIcon.appiconset" -maxdepth 1 -iname '*1024*.png' -print -quit 2>/dev/null | grep -q .; then pass "1024 px App Store icon asset exists";
else fail "1024 px App Store icon asset is missing"; fi
if grep -R -q -E 'sk-[A-Za-z0-9_-]{20,}' "$ROOT_DIR/Recoco" "$ROOT_DIR/functions" --include='*.swift' --include='*.js' --include='*.json' --include='*.env*' 2>/dev/null; then fail "A value resembling an API key exists in app or function sources";
else pass "No API key pattern was found in app or function sources"; fi
if [[ "$WITH_AI" == true ]]; then
  for file in AI_BACKEND_SETUP.md firebase.json functions/package.json functions/index.js functions/narrative.test.js scripts/configure_ai_backend.sh .firebaserc; do check_file "$file" "$file AI configuration"; done
  if command -v node >/dev/null 2>&1; then
    if node --test "$ROOT_DIR/functions/narrative.test.js" >/dev/null 2>&1; then pass "Narrative server helper tests pass"; else fail "Narrative server helper tests failed"; fi
  else fail "Node.js is unavailable; explicitly requested AI checks cannot run"; fi
fi
if [[ "$RUN_TESTS" == true ]]; then
  destination="${RECOCO_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
  # These tests seed/reset data. Never run them on a user's physical phone.
  if [[ "$destination" != platform=iOS\ Simulator,* ]]; then fail "--run-tests only accepts an iOS Simulator destination; physical user data must not be seeded/reset";
  elif xcodebuild test -project "$ROOT_DIR/Recoco.xcodeproj" -scheme Recoco -configuration Debug -destination "$destination"; then pass "Automated simulator tests passed (Debug fixtures; not distribution validation)";
  else fail "Automated simulator tests failed"; fi
fi
printf '\nSummary: %d passed, %d warning(s), %d code/config failure(s), %d distribution blocker(s)\n' "$passes" "$warnings" "$failures" "$distribution_blockers"
printf 'This is a preflight only. It does not validate a signed archive, TestFlight installation, paid membership, public policy URLs, App Privacy answers, or App Review approval.\n'
if [[ "$failures" -gt 0 || "$distribution_blockers" -gt 0 ]]; then exit 1; fi
exit 0
