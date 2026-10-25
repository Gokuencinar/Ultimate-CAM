#!/bin/bash
set -euo pipefail
scheme=${1:-rootless}
case "$scheme" in
  rootless) prefix=/var/jb; architecture=iphoneos-arm64; interpreter=/var/jb/bin/sh; tweak_directory=/usr/lib/TweakInject; roothide=0 ;;
  roothide) prefix=; architecture=iphoneos-arm64e; interpreter=/bin/sh; tweak_directory=/Library/MobileSubstrate/DynamicLibraries; roothide=1 ;;
  *) echo "Unsupported package scheme: $scheme" >&2; exit 2 ;;
esac
mkdir -p build/native-night
for tool in ldid dpkg-deb; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [ "$tool" = dpkg-deb ]; then brew install dpkg; else brew install ldid; fi
  fi
done
xcrun clang -std=c11 -Wall -Wextra -Werror NativeBridge/tools/NativeNightProtocolChecks.c -o build/native-night/protocol-checks
build/native-night/protocol-checks | tee build/native-night/protocol-checks.log
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min=18.0 -dynamiclib -fobjc-arc -Wall -Wextra -Werror -DUCN_ROOTHIDE="$roothide" \
  -framework Foundation -framework UIKit -install_name @rpath/UltimateCAMNativeNight.dylib \
  NativeBridge/UltimateCAMNativeNight.m -o build/native-night/UltimateCAMNativeNight.dylib
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min=18.0 -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation NativeBridge/tools/UCNativeNightCtl.m -o build/native-night/uc-native-night
ldid -S build/native-night/UltimateCAMNativeNight.dylib
ldid -S build/native-night/uc-native-night
stage=$(mktemp -d "${TMPDIR:-/tmp}/ultimatecam-native.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/DEBIAN" "$stage$prefix$tweak_directory" "$stage$prefix/usr/bin"
cp build/native-night/UltimateCAMNativeNight.dylib NativeBridge/UltimateCAMNativeNight.plist "$stage$prefix$tweak_directory/"
cp build/native-night/uc-native-night "$stage$prefix/usr/bin/"
commit=$(git rev-parse HEAD)
version="0.1.0+build.${GITHUB_RUN_NUMBER:-1}.git.${commit:0:7}"
cat > "$stage/DEBIAN/control" <<EOF
Package: com.gokuencinar.ultimatecam.native-night
Name: Ultimate CAM Native Night
Version: $version
Architecture: $architecture
Maintainer: Gokuencinar
Author: Gokuencinar
Section: Tweaks
Depends: firmware (>= 18.7), ellekit
Description: Scoped expiring native Camera Night intent for iPhone12,3 build22H31. No automatic capture.
Homepage: https://github.com/Gokuencinar/Ultimate-CAM
EOF
cat > "$stage/DEBIAN/prerm" <<EOF
#!$interpreter
if [ -x $prefix/usr/bin/uc-native-night ]; then $prefix/usr/bin/uc-native-night disarm >/dev/null; fi
exit 0
EOF
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$stage/DEBIAN/prerm" "$stage$prefix/usr/bin/uc-native-night"
python3 - "$stage" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
(root/'DEBIAN/md5sums').write_text(''.join(hashlib.md5(p.read_bytes()).hexdigest()+'  '+p.relative_to(root).as_posix()+'\n' for p in sorted(root.rglob('*')) if p.is_file() and 'DEBIAN' not in p.relative_to(root).parts))
PY
name="Ultimate-CAM-Native-Night_${version}_${architecture}.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "build/native-night/$name"
cd build/native-night
shasum -a 256 "$name" UltimateCAMNativeNight.dylib uc-native-night > SHA256SUMS.txt
printf '%s\n' "$commit" > SOURCE-COMMIT.txt
