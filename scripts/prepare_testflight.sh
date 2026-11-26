#!/usr/bin/env bash
# Creates an archive only. Never installs, resets, exports, or uploads an app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=""
team=""
usage() {
  cat <<'USAGE'
Usage: scripts/prepare_testflight.sh --unsigned
       scripts/prepare_testflight.sh --team YOUR_TEAM_ID

--unsigned  Verify the Release archive locally; NOT usable for TestFlight.
--team      Archive with the paid Developer Program team configured in Xcode.
            A team ID alone does not prove membership or App Store access.

Optional environment:
  RECOCO_PACKAGE_CACHE  Existing Xcode SourcePackages directory.
  RECOCO_ARCHIVE_PATH   New archive path (an existing archive is never replaced).
  RECOCO_DERIVED_DATA_PATH  Fresh build directory when dependencies change.
  RECOCO_AUTH_SCOPE     apple for optional native Apple login; default local.

This command never installs on an iPhone or uploads to Apple.
USAGE
}
case "${1:-}" in
  --unsigned) [[ $# == 1 ]] || { usage; exit 2; }; mode=unsigned ;;
  --team)
    [[ $# == 2 && "$2" =~ ^[A-Z0-9]{10}$ ]] || { usage; exit 2; }
    mode=signed; team="$2" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

case "${RECOCO_AUTH_SCOPE:-local}" in
  local|apple) ;;
  *) printf 'Unknown auth scope.\n' >&2; exit 2 ;;
esac

archive="${RECOCO_ARCHIVE_PATH:-$ROOT_DIR/build/testflight/Recoco-$(date +%Y%m%d-%H%M%S)-$mode.xcarchive}"
[[ ! -e "$archive" ]] || { printf 'Archive already exists: %s\n' "$archive" >&2; exit 2; }
mkdir -p "$(dirname "$archive")"
args=(archive -project "$ROOT_DIR/Recoco.xcodeproj" -scheme Recoco
  -configuration Release -destination 'generic/platform=iOS'
  -archivePath "$archive" -derivedDataPath "${RECOCO_DERIVED_DATA_PATH:-$ROOT_DIR/build/testflight/DerivedData}"
  -disableAutomaticPackageResolution -skipPackageUpdates)
if [[ -n "${RECOCO_PACKAGE_CACHE:-}" ]]; then
  [[ -d "$RECOCO_PACKAGE_CACHE" ]] || { printf 'Package cache not found.\n' >&2; exit 2; }
  args+=(-clonedSourcePackagesDirPath "$RECOCO_PACKAGE_CACHE")
fi
if [[ "$mode" == unsigned ]]; then
  args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
  preflight_args=(--team "$team")
  if [[ "${RECOCO_AUTH_SCOPE:-local}" == apple ]]; then preflight_args+=(--with-apple-auth); fi
  "$ROOT_DIR/scripts/release_preflight.sh" "${preflight_args[@]}"
  args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$team" CODE_SIGN_STYLE=Automatic)
fi
xcodebuild "${args[@]}" >"$archive.log" 2>&1 || {
  tail -60 "$archive.log" >&2
  exit 1
}

app="$archive/Products/Applications/Recoco.app"
info="$app/Info.plist"
[[ -f "$info" ]] || { printf 'Archive has no Recoco.app.\n' >&2; exit 1; }
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
[[ "$bundle" == app.recoco.ios ]] || { printf 'Unexpected release bundle ID.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :RECOCO_SUBSCRIPTIONS_ENABLED' "$info")" == false ]] || {
  printf 'Subscriptions unexpectedly enabled.\n' >&2; exit 1;
}
if [[ "${RECOCO_AUTH_SCOPE:-local}" == apple ]]; then
  [[ -f "$app/GoogleService-Info.plist" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$app/GoogleService-Info.plist")" == "$bundle" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :RECOCO_APPLE_LOGIN_ENABLED' "$info")" == true ]] || {
      printf 'Apple login archive configuration is incomplete.\n' >&2; exit 1;
    }
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$info" >/dev/null 2>&1; then
    printf 'Unexpected social callback scheme in Apple-only release.\n' >&2; exit 1
  fi
else
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$info" >/dev/null 2>&1 ||
     [[ -e "$app/GoogleService-Info.plist" ]] ||
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :RECOCO_APPLE_LOGIN_ENABLED' "$info" 2>/dev/null || true)" == true ]]; then
    printf 'Unexpected account configuration in local-only release.\n' >&2; exit 1
  fi
fi
if [[ "$mode" == signed ]]; then
  codesign --verify --deep --strict "$app"
fi
printf 'Archive built: %s (%s), %s\n%s\n' "$version" "$build" "$bundle" "$archive"
if [[ "$mode" == unsigned ]]; then
  printf 'UNSIGNED: build verification only. Rebuild with the paid Team before TestFlight.\n'
else
  printf 'Signed archive ready for Organizer validation. Nothing has been uploaded.\n'
fi
