#!/bin/bash
set -euo pipefail
app=build/DerivedData/Build/Products/Release-iphoneos/UltimateCAM.app
stage=$(mktemp -d "${TMPDIR:-/tmp}/ultimatecam-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/var/jb/Applications/UltimateCAM.app"
mkdir -p "$stage/DEBIAN" "$(dirname "$bundle")" build
ditto "$app" "$bundle"
ldid -S "$bundle/UltimateCAM"
codesign -d --verbose=2 "$bundle/UltimateCAM" 2>&1
commit=$(git rev-parse HEAD)
version="0.1.0+git.${commit:0:7}"
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
name="Ultimate-CAM_${version}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "build/$name"
dpkg-deb --info "build/$name"
dpkg-deb --contents "build/$name"
cd build
shasum -a 256 "$name" > SHA256SUMS.txt
printf 'Commit: %s\nPaquete: %s\nEsquema: rootless /var/jb\nFirma: ad hoc ldid, sin certificado Apple\n' "$commit" "$name" > BUILD.txt
