#!/usr/bin/env bash
# Brings the string catalogs up to date with the source. Xcode does this when it
# builds in the IDE; xcodebuild only writes the .stringsdata files, so this
# builds for the simulator and merges them with xcstringstool.
#
#   scripts/sync-strings.sh          update the catalogs
#   scripts/sync-strings.sh --check  fail if any catalog is out of date (CI)
set -euo pipefail

cd "$(dirname "$0")/.."
derived=${HRAFN_DERIVED:-$(mktemp -d)}
[[ -n ${HRAFN_DERIVED:-} ]] || trap 'rm -rf "$derived"' EXIT

xcodebuild build -project Hrafn.xcodeproj -scheme Hrafn \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO -quiet

objects="$derived/Build/Intermediates.noindex"

# catalog : directory whose .stringsdata feed it
catalogs=(
  "Hrafn/Localizable.xcstrings:Hrafn.build/Debug-iphonesimulator/Hrafn.build"
  "HrafnShare/Localizable.xcstrings:Hrafn.build/Debug-iphonesimulator/HrafnShare.build"
  "HrafnNotificationService/Localizable.xcstrings:Hrafn.build/Debug-iphonesimulator/HrafnNotificationService.build"
  "Packages/HrafnKit/Sources/HrafnServices/Localizable.xcstrings:HrafnKit.build/Debug-iphonesimulator/HrafnServices.build"
  "Packages/HrafnKit/Sources/HrafnStore/Localizable.xcstrings:HrafnKit.build/Debug-iphonesimulator/HrafnStore.build"
)

status=0
for entry in "${catalogs[@]}"; do
  catalog=${entry%%:*}
  data=()
  while IFS= read -r file; do data+=("$file"); done \
    < <(find "$objects/${entry#*:}" -name '*.stringsdata' ! -name 'GeneratedStringSymbols_*')
  if [[ ${1:-} == --check ]]; then
    # The file name is the table name, so the copy keeps it.
    copy="$derived/check/$catalog"
    mkdir -p "$(dirname "$copy")"
    cp "$catalog" "$copy"
    xcrun xcstringstool sync "$copy" --stringsdata "${data[@]}"
    # Compared as JSON: xcstringstool's whitespace for empty entries varies.
    if ! python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
        "$catalog" "$copy"; then
      echo "out of date: $catalog (run scripts/sync-strings.sh)"
      status=1
    fi
  else
    xcrun xcstringstool sync "$catalog" --stringsdata "${data[@]}"
    echo "synced $catalog"
  fi
done
exit $status
