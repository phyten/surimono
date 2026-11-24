#!/bin/bash
# Package the Xcode 27.2 arm64 products for test-without-building on another Mac.
set -euo pipefail

kit=$1
products=$2
stage=$(mktemp -d "$RUNNER_TEMP/test-products.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
runtime="$stage/Runtime"
platform="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
mkdir -p "$stage/Debug" "$stage/Kit" "$runtime"
pwd -P > "$stage/checkout-path"

# Swift Build embeds each target's dependency and fixture bundles in its .xctest.
for target in Surimono{Formats,Core,Rendering}Tests; do
    ditto "$kit/$target.xctest" "$stage/Kit/$target.xctest"
done
ditto "$products/Debug/Surimono.app" "$stage/Debug/Surimono.app"
test -x "$stage/Debug/Surimono.app/Contents/PlugIns/SurimonoTests.xctest/Contents/MacOS/SurimonoTests"

# otool -L on the test binaries, XCTestCore and libXCTestSwiftSupport shows the
# public/private framework split. Hosted XCTest also uses the result/daemon transport.
cp -R "$platform"/Library/Frameworks/{Testing,XCTest,XCUIAutomation}.framework \
    "$platform"/Library/Frameworks/_Testing_*.framework \
    "$platform"/Library/PrivateFrameworks/{XCTestCore,XCTestSupport,XCTAutomationSupport}.framework \
    "$DEVELOPER_DIR"/../SharedFrameworks/{DTXConnectionServices,ResultDataPublisher,XCTDaemonControl}.framework \
    "$platform"/usr/lib/{lib_TestingInterop,libXCTestSwiftSupport,libXCTestBundleInject}.dylib \
    "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper" "$runtime/"

# Keep the layout relative to the .xctestrun and the original signed bundles intact.
runs=("$products"/Surimono_*.xctestrun)
[[ ${#runs[@]} == 1 && -f "${runs[0]}" ]]
python3 Tools/CI/relocate-xctestrun.py "${runs[0]}" "$stage/Surimono.xctestrun"

if [[ $# == 3 ]]; then
    mkdir "$stage/Snapshots"
    cp -R "$3/surimono-snapshots" "$3"/*.bundle "$stage/Snapshots/"
fi

# Actions artifacts alone lose executable modes. Archive whole bundles, including
# framework symlinks and signatures, without DerivedData, SDKs or object files.
tar -czf "$RUNNER_TEMP/test-products.tar.gz" -C "$stage" .
du -sh "$stage" "$RUNNER_TEMP/test-products.tar.gz"
