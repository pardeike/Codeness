#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/PrototypeDerivedData"
product_path="$derived_data/Build/Products/Debug/Codeness Prototype.app"
install_path="/Applications/Codeness Prototype.app"
staging_root=""
backup_path=""
installed=false

cleanup() {
  if [[ "$installed" != true && -n "$backup_path" && -e "$backup_path" && ! -e "$install_path" ]]; then
    mv "$backup_path" "$install_path"
  fi
  if [[ -n "$staging_root" && -d "$staging_root" ]]; then
    rm -rf "$staging_root"
  fi
}
trap cleanup EXIT

if pgrep -f '/Applications/Codeness Prototype.app/Contents/MacOS/Codeness Prototype' >/dev/null; then
  printf 'Quit Codeness Prototype before replacing its test build.\n' >&2
  exit 1
fi

cd "$repo_root"
xcodegen generate >/dev/null
xcodebuild \
  -quiet \
  -project Codeness.xcodeproj \
  -scheme CodenessPrototype \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

if [[ ! -d "$product_path" ]]; then
  printf 'Prototype build did not produce %s\n' "$product_path" >&2
  exit 1
fi

codesign --verify --deep --strict "$product_path"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$product_path/Contents/Info.plist")"
support_directory="$(plutil -extract CodenessApplicationSupportDirectory raw "$product_path/Contents/Info.plist")"
if [[ "$bundle_identifier" != "ap.codeness.prototype" ]]; then
  printf 'Prototype has unexpected bundle identifier: %s\n' "$bundle_identifier" >&2
  exit 1
fi
if [[ "$support_directory" != "Codeness Prototype" ]]; then
  printf 'Prototype has unsafe Application Support directory: %s\n' "$support_directory" >&2
  exit 1
fi

staging_root="$(mktemp -d /Applications/.Codeness-Prototype-install.XXXXXX)"
staged_path="$staging_root/Codeness Prototype.app"
backup_path="$staging_root/Previous.app"
ditto "$product_path" "$staged_path"
codesign --verify --deep --strict "$staged_path"

if [[ -e "$install_path" ]]; then
  mv "$install_path" "$backup_path"
fi
mv "$staged_path" "$install_path"
codesign --verify --deep --strict "$install_path"

installed=true
printf 'Installed isolated prototype at %s\n' "$install_path"
