#!/bin/bash
set -euo pipefail
app=build/DerivedData/Build/Products/Release-iphoneos/UltimateCAM.app
stage=$(mktemp -d "${TMPDIR:-/tmp}/ultimatecam-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/var/jb/Applications/UltimateCAM.app"
mkdir -p "$stage/DEBIAN" "$(dirname "$bundle")" build
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
version="0.3.0+build.${build_number}.git.${commit:0:7}"
cat > "$stage/DEBIAN/control" <<EOF
Package: com.gokuencinar.ultimatecam
Name: Ultimate CAM
Version: $version
Architecture: iphoneos-arm64
Maintainer: Gokuencinar
Author: Gokuencinar
Section: Multimedia
Depends: firmware (>= 18.0), uikittools
Description: Camara propia con captura multiple experimental e interfaz inspirada en 26CAM.
Homepage: https://github.com/Gokuencinar/Ultimate-CAM
EOF
cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/var/jb/bin/sh
set -e
if [ "$1" = configure ]; then
    /var/jb/usr/bin/uicache -p /var/jb/Applications/UltimateCAM.app
fi
exit 0
EOF
cat > "$stage/DEBIAN/prerm" <<'EOF'
#!/var/jb/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
    /var/jb/usr/bin/uicache -u /var/jb/Applications/UltimateCAM.app
fi
exit 0
EOF
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$bundle/UltimateCAM" "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
python3 - "$stage" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(p for p in (root/'var').rglob('*') if p.is_file())
(root/'DEBIAN'/'md5sums').write_text(''.join(
    hashlib.md5(p.read_bytes()).hexdigest() + '  ' + p.relative_to(root).as_posix() + '\n'
    for p in files), encoding='utf-8')
PY
name="Ultimate-CAM_${version}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "build/$name"
dpkg-deb --info "build/$name"
dpkg-deb --contents "build/$name"
cd build
shasum -a 256 "$name" > SHA256SUMS.txt
printf 'Commit: %s\nPaquete: %s\nEsquema: rootless /var/jb\nFirma: ad hoc ldid, sin certificado Apple\n' "$commit" "$name" > BUILD.txt
