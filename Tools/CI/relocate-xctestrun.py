"""Prepare this scheme's Xcode 27.2 hosted-test manifest for the macOS 15 runner."""
import plistlib
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
manifest = plistlib.loads(source.read_bytes())
target = manifest["SurimonoTests"]
if manifest["__xctestrun_metadata__"]["FormatVersion"] != 1 or not target["IsAppHostedTestBundle"]:
    raise ValueError("Unexpected Surimono hosted-test manifest")

# __TESTROOT__ is the directory of the downloaded manifest. TestHostPath,
# TestBundlePath (__TESTHOST__) and DependentProductPaths already relocate.
env = target["TestingEnvironmentVariables"]
runtime = "__TESTROOT__/Runtime"
for key in ("DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"):
    # Keep product paths. __PLATFORMS__ and __SHAREDFRAMEWORKS__ would load 26.3.
    products = [p for p in env[key].split(":") if p.startswith("__TESTROOT__/")]
    env[key] = ":".join([runtime, *products])
    env["__XPC_" + key] = env[key]

# Use the matching XCTest injector. The older controller supplies its own
# Main Thread Checker. RPAC is an optional diagnostic from the producer OS.
libraries = env["DYLD_INSERT_LIBRARIES"].split(":")
injectors = [lib for lib in libraries if lib.endswith("/libXCTestBundleInject.dylib")]
if len(injectors) != 1:
    raise ValueError("Unexpected XCTest injector path")
env["DYLD_INSERT_LIBRARIES"] = ":".join(
    runtime + "/libXCTestBundleInject.dylib" if lib == injectors[0] else lib
    for lib in libraries if lib != "/usr/lib/libRPAC.dylib"
)
launch = target["EnvironmentVariables"]
if "DYLD_INSERT_LIBRARIES" in launch:
    remaining = [lib for lib in launch.pop("DYLD_INSERT_LIBRARIES").split(":") if lib != "/usr/lib/libRPAC.dylib"]
    if remaining:
        launch["DYLD_INSERT_LIBRARIES"] = ":".join(remaining)
destination.write_bytes(plistlib.dumps(manifest, sort_keys=False))
