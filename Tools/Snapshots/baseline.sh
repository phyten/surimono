#!/bin/bash
set -euo pipefail
: "${REF:?use make snapshots-baseline REF=<git ref>}"
root=$(pwd -P)
commit=$(git rev-parse --verify --end-of-options "${REF}^{commit}")
mkdir -p build
scratch=$(mktemp -d "$root/build/snapshot-ref.XXXXXXXX")
tree="$scratch/source"
cleanup() {
    if [[ -d "$tree/.git" || -f "$tree/.git" ]]; then git worktree remove --force "$tree" || return 1; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git worktree add --detach "$tree" "$commit"
# Xcode can reuse locally resolved packages, without changing the current app's DerivedData.
if [[ -d "$1/SourcePackages" ]]; then
    cp -Rc "$1/SourcePackages" "$scratch/packages" || cp -R "$1/SourcePackages/." "$scratch/packages/"
fi
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0
xcodebuild -quiet -project "$tree/Surimono.xcodeproj" -scheme Surimono -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$scratch/DerivedData" \
    -clonedSourcePackagesDirPath "$scratch/packages" -disableAutomaticPackageResolution -skipPackageUpdates build
swift run -c release --package-path Tools/Snapshots surimono-snapshots render-ref \
    "$scratch/DerivedData/Build/Products/Debug/Surimono.app" "$tree" "$REF"
