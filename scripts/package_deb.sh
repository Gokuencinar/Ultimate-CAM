#!/bin/bash
set -euo pipefail
scheme=${1:-rootless}
case "$scheme" in
  rootless) prefix=/var/jb; architecture=iphoneos-arm64; interpreter=/var/jb/bin/sh; destination=build ;;
  roothide) prefix=; architecture=iphoneos-arm64e; interpreter=/bin/sh; destination=build/roothide ;;
  *) echo "Unsupported package scheme: $scheme" >&2; exit 2 ;;
esac
app=build/DerivedData/Build/Products/Release-iphoneos/UltimateCAM.app
stage=$(mktemp -d "${TMPDIR:-/tmp}/ultimatecam-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage$prefix/Applications/UltimateCAM.app"
mkdir -p "$stage/DEBIAN" "$(dirname "$bundle")" "$destination"
ditto "$app" "$bundle"
# Bind this ad-hoc app to its own data container. Without this, platform trust
# can deny even its own cache (observed NSCocoaErrorDomain 513 on the device).
# The string form is used by TrollStore for platform-trusted app containers:
# https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m
ldid -Sscripts/app-entitlements.plist "$bundle/UltimateCAM"
ldid -e "$bundle/UltimateCAM" > build/app-entitlements.xml
python3 - <<'PY'
import pathlib, plistlib
actual = plistlib.loads(pathlib.Path('build/app-entitlements.xml').read_bytes())
expected = plistlib.loads(pathlib.Path('scripts/app-entitlements.plist').read_bytes())
assert actual == expected, 'Signed app entitlements differ from the declared container binding'
PY
codesign -d --verbose=2 "$bundle/UltimateCAM" 2>&1
commit=$(git rev-parse HEAD)
build_number=${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD)}
version="0.18.1+build.${build_number}.git.${commit:0:7}"
cat > "$stage/DEBIAN/control" <<EOF
Package: com.gokuencinar.ultimatecam
Name: Ultimate CAM
Version: $version
Architecture: $architecture
Maintainer: Gokuencinar
Author: Gokuencinar
Section: Multimedia
Depends: firmware (>= 18.0), uikittools
Description: Ultimate CAM photo processing, video and native Night companion integration.
Homepage: https://github.com/Gokuencinar/Ultimate-CAM
EOF
cat > "$stage/DEBIAN/postinst" <<EOF
#!$interpreter
set -e
if [ "\$1" = configure ]; then
    $prefix/usr/bin/uicache -p $prefix/Applications/UltimateCAM.app
fi
exit 0
EOF
cat > "$stage/DEBIAN/prerm" <<EOF
#!$interpreter
set -e
if [ "\$1" = remove ] || [ "\$1" = deconfigure ]; then
    $prefix/usr/bin/uicache -u $prefix/Applications/UltimateCAM.app
fi
exit 0
EOF
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$bundle/UltimateCAM" "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
python3 - "$stage" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(p for p in root.rglob('*') if p.is_file() and 'DEBIAN' not in p.relative_to(root).parts)
(root/'DEBIAN'/'md5sums').write_text(''.join(
    hashlib.md5(p.read_bytes()).hexdigest() + '  ' + p.relative_to(root).as_posix() + '\n'
    for p in files), encoding='utf-8')
PY
name="Ultimate-CAM_${version}_${architecture}.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "$destination/$name"
dpkg-deb --info "$destination/$name"
dpkg-deb --contents "$destination/$name"
cd "$destination"
shasum -a 256 "$name" > SHA256SUMS.txt
