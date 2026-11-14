#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEGEN="${IMORA_XCODEGEN_PATH:-xcodegen}"
"$XCODEGEN" generate >/dev/null
mkdir -p Imora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp config/Package.resolved Imora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project Imora.xcodeproj -scheme Imora -destination "${IMORA_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -derivedDataPath "${IMORA_DERIVED_DATA:-/private/tmp/imora-implementation/DerivedData}" -clonedSourcePackagesDirPath "${IMORA_PACKAGE_CACHE:-/private/tmp/imora-package-cache}" -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test "$@"
