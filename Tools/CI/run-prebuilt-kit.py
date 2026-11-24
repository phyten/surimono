"""Run one copied SwiftPM test product and recap failures after the per-test log."""

import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

target, *options = sys.argv[1:]
temp = Path(os.environ["RUNNER_TEMP"])
runtime = temp / "test-products/Runtime"
bundle = temp / "test-products/Kit" / (target + ".xctest")
xml = temp / (target + ".xml")
xml.unlink(missing_ok=True)

# Scope dyld overrides to the SwiftPM helper. The native Xcode controller and
# xcresulttool must use the libraries from their own installation.
result = subprocess.run(
    [
        runtime / "swiftpm-testing-helper",
        "--test-bundle-path", bundle / "Contents/MacOS" / target,
        "--testing-library", "swift-testing",
        "--xunit-output", xml, *options,
    ],
    env={
        **os.environ,
        "DYLD_FRAMEWORK_PATH": str(runtime),
        "DYLD_LIBRARY_PATH": str(runtime),
        "PACKAGE_RESOURCE_BUNDLE_PATH": str(bundle / "Contents/Resources"),
    },
)
try:
    cases = ET.parse(xml).findall(".//testcase")
except (OSError, ET.ParseError) as error:
    sys.exit(f"{target}: no complete test results (helper exit {result.returncode}): {error}")
if not cases:
    sys.exit(f"{target}: no test cases recorded (helper exit {result.returncode})")

failed = skipped = 0
for case in cases:
    issues = case.findall("failure") + case.findall("error")
    if issues:
        failed += 1
        for issue in issues:
            print(f"FAIL {case.get('classname')}/{case.get('name')} | {issue.get('message') or issue.text}")
    elif case.find("skipped") is not None:
        skipped += 1
passed = len(cases) - failed - skipped
print(f"{target}: {passed} passed, {failed} failed, {skipped} skipped")
# A run in which every test was skipped has checked nothing, so it must not count as a pass.
if passed + failed == 0:
    sys.exit(f"{target}: every test was skipped")
sys.exit(1 if failed or result.returncode else 0)
