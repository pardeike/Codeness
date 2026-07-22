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

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$install_path/Contents/Info.plist")"
if [[ "$bundle_identifier" != "ap.codeness" ]]; then
  printf 'Installed Codeness has unexpected bundle identifier: %s\n' "$bundle_identifier" >&2
  exit 1
fi

install_verified=true
printf 'Installed Codeness Release at %s\n' "$install_path"
