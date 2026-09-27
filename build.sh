#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mode=${GKSDUD_SIGN_MODE:-auto}
sign_args=()
if [[ "$mode" == auto || "$mode" == developer-id ]]; then
  if [[ -z "${GKSDUD_SIGN_IDENTITY:-}" ]]; then
    identities=$(security find-identity -v -p codesigning) || {
      echo 'Unable to read code signing identities from the keychain.' >&2
      exit 1
    }
    fingerprints=()
    identity_names=()
    identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+"(Developer ID Application: [^"]+)"$'
    while IFS= read -r line; do
      if [[ "$line" =~ $identity_pattern ]]; then
        fingerprints+=("${BASH_REMATCH[1]}")
        identity_names+=("${BASH_REMATCH[2]}")
      fi
    done <<< "$identities"
    case ${#fingerprints[@]} in
      0)
        if [[ "$mode" == auto && -f signing/local-certificate.pem ]]; then
          mode=local
        else
          echo 'No valid Developer ID Application identity found. Set GKSDUD_SIGN_IDENTITY to your certificate name or SHA-1, or use GKSDUD_SIGN_MODE=local / ad-hoc.' >&2
          exit 1
        fi
        ;;
      1) GKSDUD_SIGN_IDENTITY=${fingerprints[0]} ;;
      *)
        echo 'Multiple Developer ID Application identities found. Set GKSDUD_SIGN_IDENTITY to the certificate name or SHA-1 to use:' >&2
        for ((i=0; i<${#fingerprints[@]}; i++)); do
          printf '  %s  "%s"\n' "${fingerprints[i]}" "${identity_names[i]}" >&2
        done
        exit 1
        ;;
    esac
  fi
  [[ "$mode" != auto ]] || mode=developer-id
fi
case "$mode" in
  local)
    [[ -f signing/local-certificate.pem ]] || { echo 'Missing fixed signing certificate. Run signing/setup-local-signing.sh first.' >&2; exit 1; }
    fingerprint=$(openssl x509 -in signing/local-certificate.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    [[ "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || exit 1
    sign_args=(--sign "$fingerprint" --timestamp=none --requirements "=designated => identifier \"io.gksdud.inputswitch\" and certificate leaf = H\"$fingerprint\"")
    ;;
  developer-id)
    : "${GKSDUD_SIGN_IDENTITY:?Set Developer ID Application signing identity}"
    sign_args=(--sign "$GKSDUD_SIGN_IDENTITY" --timestamp)
    ;;
  ad-hoc)
    echo 'WARNING: ad-hoc signing does not preserve app identity across updates.' >&2
    sign_args=(--sign - --timestamp=none)
    ;;
  *) echo 'GKSDUD_SIGN_MODE must be auto, local, developer-id, or ad-hoc' >&2; exit 1 ;;
esac
printf 'Signing mode: %s; identity: %s\n' "$mode" "${sign_args[1]}"
notarize=${GKSDUD_NOTARIZE:-0}
case "$notarize" in
  0) ;;
  1)
    [[ "$mode" == developer-id ]] || { echo 'Notarization requires Developer ID signing.' >&2; exit 1; }
    notary_args=(--keychain-profile "${GKSDUD_NOTARY_PROFILE:-gksdud}")
    if [[ -n "${GKSDUD_NOTARY_KEYCHAIN:-}" ]]; then
      notary_args+=(--keychain "$GKSDUD_NOTARY_KEYCHAIN")
    fi
    xcrun notarytool history "${notary_args[@]}" --output-format json >/dev/null
    ;;
  *) echo 'GKSDUD_NOTARIZE must be 0 or 1' >&2; exit 1 ;;
esac
output_dir=${GKSDUD_OUTPUT_DIR:-"$PWD/outputs"}
stage=$(mktemp -d /private/tmp/gksdud-build.XXXXXX)
mkdir -p "$stage/gksdud.app/Contents/MacOS" "$stage/gksdud.app/Contents/Resources" "$output_dir"
swiftc -parse-as-library -D ICON_GENERATOR -module-cache-path "$stage/module-cache" DudIcon.swift -o "$stage/icon-generator"
"$stage/icon-generator" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$stage/gksdud.app/Contents/Resources/AppIcon.icns"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" -module-cache-path "$stage/module-cache" -import-objc-header Bridge.h main.swift DudIcon.swift KeyboardManagement.swift KeyboardSettings.swift KeyboardTests.swift SettingsWindow.swift UpdateChecking.swift UpdateInstaller.swift SpecialCharacters.swift FeatureTests.swift -o "$stage/gksdud-$arch" -framework AppKit -framework IOKit -framework ServiceManagement
done
lipo -create "$stage/gksdud-arm64" "$stage/gksdud-x86_64" -output "$stage/gksdud.app/Contents/MacOS/gksdud"
cp Info.plist "$stage/gksdud.app/Contents/Info.plist"
cp LICENSE "$stage/gksdud.app/Contents/Resources/LICENSE"
cp Resources/github.svg Resources/OCTICONS-LICENSE "$stage/gksdud.app/Contents/Resources/"
if [[ -n "${GKSDUD_APP_VERSION:-}" ]]; then
  [[ "$GKSDUD_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GKSDUD_APP_VERSION" "$stage/gksdud.app/Contents/Info.plist"
fi
if [[ -n "${GKSDUD_BUILD_NUMBER:-}" ]]; then
  [[ "$GKSDUD_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GKSDUD_BUILD_NUMBER" "$stage/gksdud.app/Contents/Info.plist"
fi
codesign --force "${sign_args[@]}" --options runtime "$stage/gksdud.app"
codesign --verify --deep --strict "$stage/gksdud.app"
"$stage/gksdud.app/Contents/MacOS/gksdud" --self-test
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/gksdud.app/Contents/Info.plist")
if [[ "$notarize" == 1 ]]; then
  ditto -c -k --keepParent --norsrc "$stage/gksdud.app" "$stage/notarization.zip"
  echo 'Submitting app to Apple for notarization...'
  if ! xcrun notarytool submit "$stage/notarization.zip" "${notary_args[@]}" --wait --timeout 20m --output-format json > "$stage/notarization.json"; then
    echo "Notarization failed. Submission receipt: $stage/notarization.json" >&2
    exit 1
  fi
  status=$(/usr/bin/plutil -extract status raw -o - "$stage/notarization.json")
  [[ "$status" == Accepted ]] || { echo "Notarization status: $status. Submission receipt: $stage/notarization.json" >&2; exit 1; }
  xcrun stapler staple "$stage/gksdud.app"
  xcrun stapler validate "$stage/gksdud.app"
  codesign --verify --all-architectures --strict "$stage/gksdud.app"
  spctl --assess --type execute --verbose=2 "$stage/gksdud.app"
fi
# Repack after stapling; publish only a completely verified archive.
ditto -c -k --keepParent --norsrc "$stage/gksdud.app" "$stage/distribution.zip"
mv "$stage/distribution.zip" "$output_dir/gksdud-$version-macos-universal.zip"
codesign -d -r- "$stage/gksdud.app"
echo "Built app: $stage/gksdud.app"
