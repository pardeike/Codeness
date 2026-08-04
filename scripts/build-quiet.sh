#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
product_path="$derived_data/Build/Products/Release/Codeness.app"
install_path="/Applications/Codeness.app"
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
  if [[ "$signature_details" != *"TeamIdentifier=W65292CD8T"* ]]; then
    printf '%s has an unexpected code-signing Team ID.\n' "$app_path" >&2
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
}
trap cleanup EXIT

cd "$repo_root"
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
codesign --verify --deep --strict "$product_path"
verify_release_signature "$product_path"

staging_root="$(mktemp -d /Applications/.Codeness-install.XXXXXX)"
staged_path="$staging_root/Codeness.app"
backup_path="$staging_root/Previous.app"
ditto "$product_path" "$staged_path"
codesign --verify --deep --strict "$staged_path"

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

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$install_path/Contents/Info.plist")"
if [[ "$bundle_identifier" != "ap.codeness" ]]; then
  printf 'Installed Codeness has unexpected bundle identifier: %s\n' "$bundle_identifier" >&2
  exit 1
fi

install_verified=true
printf 'Installed Codeness Release at %s\n' "$install_path"
