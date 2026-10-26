#!/bin/bash
# 交叉編譯只含 H.264 解碼器的精簡 FFmpeg（LGPL，共享庫）給 Windows x64 / ARM64
set -e
cd "$(dirname "$0")"
[ -d llvm-mingw ] || { mkdir llvm-mingw && tar -xf llvm-mingw.tar.xz -C llvm-mingw --strip-components=1; }
[ -d src ] || { mkdir src && tar -xf ffmpeg-7.1.1.tar.xz -C src --strip-components=1; }
export PATH="$PWD/llvm-mingw/bin:$PATH"
build() {  # $1=x64|arm64  $2=x86_64|aarch64  $3=triple
  local out="$PWD/out/$1" bd="$PWD/build-$1"
  rm -rf "$bd" "$out"; mkdir -p "$bd" "$out"; cd "$bd"
  ../src/configure --prefix="$out" --enable-cross-compile --target-os=mingw32 --arch=$2 \
    --cross-prefix=$3- --cc=$3-clang --enable-shared --disable-static \
    --disable-everything --enable-decoder=h264 --enable-parser=h264 --enable-parser=hevc \
    --disable-programs --disable-doc --disable-avdevice --disable-avformat --disable-avfilter \
    --disable-swresample --disable-network --disable-autodetect --disable-debug --enable-swscale \
    --extra-ldflags="-static-libgcc"
  make -j8
  make install
  cd ..
}
build x64 x86_64 x86_64-w64-mingw32
build arm64 aarch64 aarch64-w64-mingw32
echo ALL-DONE
