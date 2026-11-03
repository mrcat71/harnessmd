#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift --version
swift build --disable-automatic-resolution
NSUnbufferedIO=YES swift test --disable-automatic-resolution --no-parallel
CONFIGURATION=release sh build.sh
dist/harnessmd.app/Contents/MacOS/HarnessApp --self-test
