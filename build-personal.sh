#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This iOS build requires macOS with Xcode.' >&2
  exit 1
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p personal-build
# Pin the JIT dependency rather than taking future changes automatically.
stik_commit=32287268fa5824f9edce4cb359f5833ce0cf7b00
if [[ ! -d personal-build/StikJIT/.git ]]; then
  git clone https://github.com/StikDebug/StikJIT.git personal-build/StikJIT
fi
git -C personal-build/StikJIT checkout --detach "$stik_commit"
(
  cd personal-build/StikJIT
  xcodegen generate
  xcodebuild archive -project StikJIT.xcodeproj -scheme StikJIT \
    -destination 'generic/platform=iOS' -archivePath ../StikJIT-iOS \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO
)
if [[ ! -d personal-build/StikJIT.xcframework ]]; then
  xcodebuild -create-xcframework \
    -framework personal-build/StikJIT-iOS.xcarchive/Products/Library/Frameworks/StikJIT.framework \
    -output personal-build/StikJIT.xcframework
fi
(
  cd JITHelper
  xcodegen generate
  xcodebuild -project AmethystJIT.xcodeproj -scheme AMJITHelper \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath ../personal-build/Helper CODE_SIGNING_ALLOWED=NO build
)
git submodule update --init --recursive
gmake -j"$(sysctl -n hw.ncpu)" payload PLATFORM=2 SLIMMED=0 BOOTJDK="${JAVA_HOME:?Set JAVA_HOME to JDK 8}/bin"
app="$PWD/artifacts/Payload/AngelAuraAmethyst.app"
mkdir -p "$app/PlugIns"
ditto personal-build/Helper/Build/Products/Release-iphoneos/AMJITHelper.appex "$app/PlugIns/AMJITHelper.appex"
# Extension frameworks belong in the containing app's Frameworks directory.
# The host does not link StikJIT; only the helper loads it through its rpath.
if [[ -d "$app/PlugIns/AMJITHelper.appex/Frameworks" ]]; then
  ditto "$app/PlugIns/AMJITHelper.appex/Frameworks" "$app/Frameworks"
  rm -rf "$app/PlugIns/AMJITHelper.appex/Frameworks"
fi
for runtime in java-8-openjdk java-21-openjdk java-25-openjdk; do
  rm -rf "$app/java_runtimes/$runtime"
done
test -f "$app/java_runtimes/java-17-openjdk/release"
mkdir -p "$app/ThirdPartyLicenses"
cp personal-build/StikJIT/LICENSE "$app/ThirdPartyLicenses/StikJIT-MPL-2.0.txt"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Amethyst 1.19.1' "$app/Info.plist"
find "$app/Frameworks" -type f -perm +111 -exec sh -c 'file "$1" | grep -q Mach-O && ldid -S "$1" || true' _ {} \;
ldid -S "$app/PlugIns/AMJITHelper.appex/AMJITHelper"
ldid -Sentitlements.sideload.xml "$app/AngelAuraAmethyst"
(
  cd artifacts
  zip -qry --symlinks Amethyst-1.19.1-BuiltinJIT-experimental.ipa Payload
)
echo 'Built artifacts/Amethyst-1.19.1-BuiltinJIT-experimental.ipa'
