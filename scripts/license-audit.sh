#!/usr/bin/env bash
# Fails the build if a dependency is not permissively licensed.
#
# Hrafn implements XMPP clean-room from the RFCs and XEPs; a copyleft dependency
# would defeat that, so the allowlist is enforced rather than reviewed by hand.
set -euo pipefail

cd "$(dirname "$0")/.."
# Every resolved dependency graph: each package, and the app's (which Xcode
# writes when it resolves the local packages together).
RESOLVED_FILES=(
  "Packages/XMPPKit/Package.resolved"
  "Packages/HrafnKit/Package.resolved"
  "Packages/OMEMOKit/Package.resolved"
  "Hrafn.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

# Permissive licences only (MIT, BSD-2/3, Apache-2.0, zlib, ISC).
ALLOWED_PACKAGES=(
  # name|expected licence — add a line per approved dependency.
  "swift-nio|Apache-2.0"
  "swift-nio-transport-services|Apache-2.0"
  "grdb.swift|MIT"
  "swift-sodium|ISC"
)

status=0

echo "==> dependency audit"
for resolved in "${RESOLVED_FILES[@]}"; do
  if [[ ! -f "$resolved" ]]; then
    echo "   (not resolved yet: $resolved)"
    continue
  fi
  echo "   $resolved"
  names=$(python3 - "$resolved" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    resolved = json.load(handle)
pins = resolved.get("pins") or resolved.get("object", {}).get("pins", [])
for pin in pins:
    print(pin.get("identity") or pin.get("package", "?"))
PY
)
  if [[ -z "$names" ]]; then
    echo "   ok      no external dependencies"
  fi
  for name in $names; do
    match=""
    for entry in "${ALLOWED_PACKAGES[@]}"; do
      if [[ "${entry%%|*}" == "$name" ]]; then match="${entry##*|}"; fi
    done
    if [[ -z "$match" ]]; then
      echo "   DENIED  $name is not on the permissive-licence allowlist"
      status=1
    else
      echo "   ok      $name ($match)"
    fi
  done
done

# The protocol package stays free of dependencies (docs/LICENSING.md).
if [[ -f "Packages/XMPPKit/Package.resolved" ]] && grep -q '"identity"' "Packages/XMPPKit/Package.resolved"; then
  echo "   DENIED  XMPPKit must not depend on external packages"
  status=1
fi

echo "==> copyleft scan of vendored sources"
# Catches a GPL/AGPL file pasted into the tree, the failure mode the clean-room
# policy exists to prevent.
if grep -rIl --exclude-dir=.git --exclude-dir=.build --exclude="license-audit.sh" \
    -E "GNU (GENERAL|LESSER GENERAL|AFFERO GENERAL) PUBLIC LICENSE" . ; then
  echo "   DENIED  copyleft licence text found in the tree"
  status=1
else
  echo "   ok      no copyleft licence text in tree"
fi

echo "==> forbidden-source scan"
# Known copyleft XMPP clients. Referencing them by name in source is a smell
# that implementation detail came from reading their code.
# Documentation may discuss them; source may not.
if grep -rIn --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs \
    --include="*.swift" --include="*.h" --include="*.c" --include="*.m" \
    -E "(Siskin|MartinIM|libsignal)" . ; then
  echo "   WARNING clean-room policy: review the references above"
fi

exit $status
