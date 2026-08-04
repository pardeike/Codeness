#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
product_path="$derived_data/Build/Products/Release/Codeness.app"
install_path="/Applications/Codeness.app"
expected_team_id="W65292CD8T"
signing_identity="${CODENESS_CODESIGN_IDENTITY:-Developer ID Application: Andreas Pardeike ($expected_team_id)}"
signing_keychain="${CODENESS_CODESIGN_KEYCHAIN:-}"
notary_profile="${CODENESS_NOTARY_PROFILE:-brrainz-notary}"
notary_keychain="${CODENESS_NOTARY_KEYCHAIN:-}"
notary_root=""
staging_root=""
staged_path=""
backup_path=""
install_verified=false

verify_release_signature() {
  local app_path="$1"
  local signature_details
  local entitlements_file
  local apple_events
  local get_task_allow

  signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
  if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
    printf '%s is not signed by a Developer ID Application authority.\n' "$app_path" >&2
    return 1
  fi
  if [[ "$signature_details" != *"Identifier=ap.codeness"* ]]; then
    printf '%s has an unexpected code-signing identifier.\n' "$app_path" >&2
    return 1
  fi
  if [[ "$signature_details" != *"TeamIdentifier=$expected_team_id"* ]]; then
    printf '%s has an unexpected code-signing Team ID.\n' "$app_path" >&2
    return 1
  fi
  if [[ "$signature_details" != *"flags=0x10000(runtime)"* ]]; then
    printf '%s is not signed with the hardened runtime.\n' "$app_path" >&2
    return 1
  fi
  if [[ "$signature_details" != *"Timestamp="* || "$signature_details" == *"Timestamp=none"* ]]; then
    printf '%s is missing a trusted signing timestamp.\n' "$app_path" >&2
    return 1
  fi

  entitlements_file="$(mktemp "${TMPDIR:-/tmp}/codeness-entitlements.XXXXXX")"
  if ! codesign --display --entitlements :- "$app_path" \
    >"$entitlements_file" 2>/dev/null; then
    rm -f "$entitlements_file"
    printf 'Could not inspect entitlements for %s.\n' "$app_path" >&2
    return 1
  fi
  apple_events="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.automation.apple-events' \
      "$entitlements_file" 2>/dev/null || true
  )"
  get_task_allow="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.get-task-allow' \
      "$entitlements_file" 2>/dev/null || true
  )"
  rm -f "$entitlements_file"
  if [[ "$apple_events" != "true" ]]; then
    printf '%s is missing the Apple Events automation entitlement.\n' "$app_path" >&2
    return 1
  fi
  if [[ "$get_task_allow" == "true" ]]; then
    printf '%s unexpectedly allows debugger attachment in Release.\n' "$app_path" >&2
    return 1
  fi
}

verify_notarization() {
  local app_path="$1"
  local gatekeeper_details

  if ! xcrun stapler validate "$app_path" >/dev/null; then
    printf '%s does not contain a valid stapled notarization ticket.\n' "$app_path" >&2
    return 1
  fi
  if ! gatekeeper_details="$(spctl --assess --type execute --verbose=2 "$app_path" 2>&1)"; then
    printf '%s\n' "$gatekeeper_details" >&2
    return 1
  fi
  if [[ "$gatekeeper_details" != *"source=Notarized Developer ID"* ]]; then
    printf '%s did not pass Gatekeeper as a notarized Developer ID app:\n%s\n' \
      "$app_path" "$gatekeeper_details" >&2
    return 1
  fi
}

cleanup() {
  if [[ "$install_verified" != true && -n "$staging_root" && -d "$staging_root" ]]; then
    if [[ -n "$backup_path" && -e "$backup_path" ]]; then
      if [[ -e "$install_path" ]]; then
        rm -rf "$install_path"
      fi
      mv "$backup_path" "$install_path"
    elif [[ -n "$staged_path" && ! -e "$staged_path" && -e "$install_path" ]]; then
      rm -rf "$install_path"
    fi
  fi
  if [[ -n "$staging_root" && -d "$staging_root" ]]; then
    rm -rf "$staging_root"
  fi
  if [[ -n "$notary_root" && -d "$notary_root" ]]; then
    rm -rf "$notary_root"
  fi
}
trap cleanup EXIT

cd "$repo_root"

available_identities="$(security find-identity -v -p codesigning)"
if [[ "$available_identities" != *"$signing_identity"* ]]; then
  printf 'Code-signing identity not found: %s\n' "$signing_identity" >&2
  exit 1
fi

xcodegen generate >/dev/null
xcodebuild \
  -quiet \
  -project Codeness.xcodeproj \
  -scheme Codeness \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

if [[ ! -d "$product_path" ]]; then
  printf 'Release build did not produce %s\n' "$product_path" >&2
  exit 1
fi

codesign_args=(
  --force
  --timestamp
  --options runtime
  --sign "$signing_identity"
  --entitlements "$repo_root/Codeness.entitlements"
)
if [[ -n "$signing_keychain" ]]; then
  codesign_args+=(--keychain "$signing_keychain")
fi
codesign "${codesign_args[@]}" "$product_path"

codesign --verify --deep --strict "$product_path"
verify_release_signature "$product_path"

bundle_version="$(plutil -extract CFBundleShortVersionString raw "$product_path/Contents/Info.plist")"
notary_root="$(mktemp -d "${TMPDIR:-/tmp}/Codeness-notary.XXXXXX")"
notary_archive="$notary_root/Codeness-$bundle_version-notarization.zip"
notary_result="$notary_root/result.json"
ditto -c -k --keepParent --norsrc "$product_path" "$notary_archive"

notary_args=(--keychain-profile "$notary_profile")
if [[ -n "$notary_keychain" ]]; then
  notary_args+=(--keychain "$notary_keychain")
fi
if xcrun notarytool submit "$notary_archive" \
  "${notary_args[@]}" \
  --wait \
  --output-format json \
  >"$notary_result"; then
  :
else
  submit_exit=$?
  printf 'Apple notarization submission failed:\n' >&2
  cat "$notary_result" >&2
  exit "$submit_exit"
fi

notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
notary_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
if [[ "$notary_status" != "Accepted" ]]; then
  printf 'Apple notarization was not accepted:\n' >&2
  cat "$notary_result" >&2
  exit 1
fi
printf 'Apple notarization accepted: %s\n' "$notary_id"

xcrun stapler staple "$product_path" >/dev/null
verify_notarization "$product_path"

staging_root="$(mktemp -d /Applications/.Codeness-install.XXXXXX)"
staged_path="$staging_root/Codeness.app"
backup_path="$staging_root/Previous.app"
ditto "$product_path" "$staged_path"
codesign --verify --deep --strict "$staged_path"
verify_release_signature "$staged_path"
verify_notarization "$staged_path"

if [[ -e "$install_path" ]]; then
  mv "$install_path" "$backup_path"
fi

if ! mv "$staged_path" "$install_path"; then
  printf 'Could not install Codeness at %s\n' "$install_path" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$install_path"; then
  printf 'Installed Codeness failed code-signature verification.\n' >&2
  exit 1
fi
verify_release_signature "$install_path"
verify_notarization "$install_path"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$install_path/Contents/Info.plist")"
if [[ "$bundle_identifier" != "ap.codeness" ]]; then
  printf 'Installed Codeness has unexpected bundle identifier: %s\n' "$bundle_identifier" >&2
  exit 1
fi

install_verified=true
printf 'Installed Codeness Release at %s\n' "$install_path"
