#!/usr/bin/env bash
set -euo pipefail

VERSION="v1.0.0"
DIST_DIR="dist"

echo "==> Building zap release ${VERSION}..."
mkdir -p "${DIST_DIR}"
rm -rf "${DIST_DIR}/*"

# Linux x86_64
echo "==> Building Linux x86_64 (musl)..."
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl
tar -czf "${DIST_DIR}/zap-${VERSION}-x86_64-linux.tar.gz" -C zig-out/bin zap

# Linux aarch64
echo "==> Building Linux aarch64 (musl)..."
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
tar -czf "${DIST_DIR}/zap-${VERSION}-aarch64-linux.tar.gz" -C zig-out/bin zap

# Windows x86_64
echo "==> Building Windows x86_64..."
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
if command -v zip &> /dev/null; then
  zip -j "${DIST_DIR}/zap-${VERSION}-x86_64-windows.zip" zig-out/bin/zap.exe
else
  tar -czf "${DIST_DIR}/zap-${VERSION}-x86_64-windows.tar.gz" -C zig-out/bin zap.exe
fi

# Checksums
echo "==> Generating SHA256SUMS.txt..."
(cd "${DIST_DIR}" && sha256sum * > SHA256SUMS.txt)

echo "==> All release archives built successfully in ${DIST_DIR}/:"
ls -lh "${DIST_DIR}"
