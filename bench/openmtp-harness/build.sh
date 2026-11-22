#!/bin/bash
# build.sh [stock|zlpfix] [homebrew|openmtp]
# Builds the harness into ./out/. Defaults: stock engine, Homebrew libusb.
#   stock   go-mtpx@18f12db + go-mtpfs@1c3302b, as linked into OpenMTP 3.3.0's kalam.dylib
#   zlpfix  the same plus zlpfix.patch (NOT what OpenMTP 3.3.0 ships)
#   homebrew  link against `brew install libusb` (the SP3000 run used 1.0.30)
#   openmtp   link against the libusb.dylib bundled in /Applications/OpenMTP.app (the Lenovo run)
set -euo pipefail
cd "$(dirname "$0")"
engine=${1:-stock}
lib=${2:-homebrew}
here=$PWD
mkdir -p out

case "$lib" in
  homebrew) ;;
  openmtp)
    app=${OPENMTP_APP:-/Applications/OpenMTP.app}
    src="$app/Contents/Resources/bin/$(uname -m | sed 's/x86_64/amd64/')/libusb.dylib"
    [[ -f "$src" ]] || { echo "missing $src"; exit 1; }
    inc=$(brew --prefix libusb)/include  # headers only; the binary is OpenMTP's
    mkdir -p out/libusb-openmtp/lib out/libusb-openmtp/pkgconfig
    cp "$src" out/libusb-openmtp/lib/libusb-1.0.dylib
    install_name_tool -id "$here/out/libusb-openmtp/lib/libusb-1.0.dylib" out/libusb-openmtp/lib/libusb-1.0.dylib
    codesign -f -s - out/libusb-openmtp/lib/libusb-1.0.dylib
    cat > out/libusb-openmtp/pkgconfig/libusb-1.0.pc <<EOF
libdir=$here/out/libusb-openmtp/lib
includedir=$inc
Name: libusb-1.0
Description: OpenMTP 3.3.0 bundled libusb (binary), Homebrew headers
Version: 1.0.24
Libs: -L\${libdir} -lusb-1.0
Cflags: -I\${includedir}/libusb-1.0
EOF
    export PKG_CONFIG_PATH="$here/out/libusb-openmtp/pkgconfig"
    ;;
  *) echo "unknown libusb choice: $lib"; exit 1 ;;
esac

# Go's build cache can reuse a cgo package linked against a different libusb, so keep one cache
# per libusb choice.
export GOCACHE="$here/out/gocache-$lib"
name=openmtp-bench-$engine-$lib
case "$engine" in
  stock) go build -o "out/$name" . ;;
  zlpfix)
    rm -rf out/go-mtpfs-zlpfix
    cp -R third_party/go-mtpfs out/go-mtpfs-zlpfix
    patch -s -d out/go-mtpfs-zlpfix -p1 < zlpfix.patch
    cp go.mod out/zlpfix.mod
    cp go.sum out/zlpfix.sum
    go mod edit -replace=github.com/ganeshrvel/go-mtpfs=./out/go-mtpfs-zlpfix out/zlpfix.mod
    go build -modfile=out/zlpfix.mod -o "out/$name" .
    ;;
  *) echo "unknown engine: $engine"; exit 1 ;;
esac
otool -L "out/$name" | grep -i usb
echo "built out/$name"
