#!/usr/bin/env bash
# CI smoke test: translate every Anime4K GLSL shader to Metal, compile the MSL,
# then run a full offline transcode of a generated test movie.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/Anime4KMetalTool"
BUILD="./build"
rm -rf "$BUILD"
mkdir -p "$BUILD/translate" "$BUILD/Res.bundle/glsl"
cp -R "$APP/glsl/." "$BUILD/Res.bundle/glsl/"
cat > "$BUILD/Res.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>anime4k.harness.resources</string>
<key>CFBundleName</key><string>HarnessResources</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

echo "== compile harness =="
xcrun swiftc -O -o "$BUILD/harness" \
  main.swift \
  "$APP/MPVShader.swift" \
  "$APP/Anime4K.swift" \
  "$APP/OfflineTranscoder.swift" \
  -framework AVFoundation -framework CoreImage -framework Metal -framework MetalKit

echo "== compile metallib =="
xcrun -sdk macosx metal -c "$APP/CenterResize.metal" -o "$BUILD/CenterResize.air"
xcrun -sdk macosx metal -c "$APP/UpscalePresent.metal" -o "$BUILD/UpscalePresent.air"
xcrun -sdk macosx metallib "$BUILD/CenterResize.air" "$BUILD/UpscalePresent.air" -o "$BUILD/default.metallib"

echo "== translate GLSL -> Metal =="
"$BUILD/harness" translate "$APP/glsl" "$BUILD/translate"

echo "== compile translated MSL =="
msl_fail=0
for f in "$BUILD"/translate/*.metal; do
  if ! xcrun -sdk macosx metal -c "$f" -o "${f%.metal}.air" >"${f%.metal}.log" 2>&1; then
    echo "MSL_COMPILE_FAIL: $f"
    cat "${f%.metal}.log" || true
    msl_fail=1
  fi
done
if [ "$msl_fail" -ne 0 ]; then
  echo "some translated shaders failed to compile"
  exit 1
fi
echo "all translated shaders compiled"

echo "== full transcode smoke =="
A4K_METALLIB="$BUILD/default.metallib" "$BUILD/harness" smoke "$BUILD/out.mp4" "$BUILD/Res.bundle"
ls -lh "$BUILD/out.mp4" || true
echo "SMOKE_PASSED"
