#!/usr/bin/env bash
# whisper.cpp（tools/whisper.cpp）から macOS 用の tools/whisper.xcframework を作る。
#
# 使い方: scripts/build-whisper-xcframework.sh [--force]
#   --force   tools/whisper.xcframework があっても作り直す（既定は作成済みならスキップ）
#   JOBS      ビルドの並列数（既定: 論理 CPU 数）
#
# 公式の whisper-b5454-xcframework.zip の x86_64 スライスは AVX/AVX2/FMA/F16C なしでビルドされていて
# Intel Mac で約 7 倍遅い（docs/superpowers/research/2026-10-24-spike-results.md 項目 8）。そのため:
#   - x86_64: 上流の macOS 用フラグ + -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
#             （GGML_NATIVE=ON にしない。ビルドした Mac の CPU、たとえば AVX-512 に依存させない）
#   - arm64:  上流の macOS 用フラグのまま（Metal・Core ML）
# を別々にビルドし（x86 専用の -m フラグは universal ビルドを壊す）、lipo で 1 つのフレームワークにまとめる。
# フレームワーク名・bundle id・module.modulemap・ヘッダは上流の build-xcframework.sh と同じにする。
set -euo pipefail

FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=1 ;;
        -h|--help) sed -n "2,15p" "$0"; exit 0 ;;
        *) echo "不明な引数: ${arg}（使えるのは --force）" >&2; exit 64 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${ROOT}/tools/whisper.cpp"
WHISPER_TAG="v1.9.5"   # = b5454（commit d1be6fd）。scripts/setup-whisper.sh と同じタグ
OUTPUT="${ROOT}/tools/whisper.xcframework"
MACOS_MIN_OS_VERSION=26.0
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

log() { echo "[build-whisper-xcframework] $*"; }

if [[ "${FORCE}" -eq 0 && -f "${OUTPUT}/Info.plist" ]]; then
    log "${OUTPUT} は作成済み。スキップ（作り直すなら --force）"
    exit 0
fi

for tool in cmake xcodebuild libtool lipo; do
    command -v "${tool}" >/dev/null || { echo "${tool} が見つからない" >&2; exit 1; }
done

# 1. ソース（scripts/setup-whisper.sh と同じタグを clone する。モデルの取得やベンチ用ビルドはしない）
if [[ ! -f "${WHISPER_DIR}/CMakeLists.txt" ]]; then
    log "clone: ${WHISPER_TAG}"
    mkdir -p "${ROOT}/tools"
    git clone --depth 1 --branch "${WHISPER_TAG}" https://github.com/ggml-org/whisper.cpp "${WHISPER_DIR}"
fi
cd "${WHISPER_DIR}"

GENERATOR=()
command -v ninja >/dev/null && GENERATOR=(-G Ninja)

# 上流 build-xcframework.sh の macOS 用オプション（Xcode 用の属性とデバッグ情報 -g は除く）
COMMON_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN_OS_VERSION}"
    -DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DWHISPER_COREML=ON
    -DWHISPER_COREML_ALLOW_FALLBACK=ON
)
X86_64_CMAKE_ARGS=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)

# build_arch <arch> <追加の CMake 引数...>: build-xcf-<arch>/ に静的ライブラリを作り、1 つの dylib にまとめる
build_arch() {
    local arch="$1"; shift
    local dir="build-xcf-${arch}"
    log "${arch} をビルド（${dir}/、-j${JOBS}）"
    rm -rf "${dir}"
    cmake -B "${dir}" "${GENERATOR[@]}" "${COMMON_CMAKE_ARGS[@]}" -DCMAKE_OSX_ARCHITECTURES="${arch}" "$@" -S .
    cmake --build "${dir}" --config Release -j "${JOBS}"

    # 上流 combine_static_libraries と同じ組み合わせ
    local libs=(
        "${dir}/src/libwhisper.a"
        "${dir}/src/libparakeet.a"
        "${dir}/src/libwhisper.coreml.a"
        "${dir}/ggml/src/libggml.a"
        "${dir}/ggml/src/libggml-base.a"
        "${dir}/ggml/src/libggml-cpu.a"
        "${dir}/ggml/src/ggml-metal/libggml-metal.a"
        "${dir}/ggml/src/ggml-blas/libggml-blas.a"
    )
    libtool -static -o "${dir}/combined.a" "${libs[@]}" 2>/dev/null
    xcrun -sdk macosx clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
        -arch "${arch}" \
        -mmacosx-version-min="${MACOS_MIN_OS_VERSION}" \
        -Wl,-force_load,"${dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate -framework CoreML \
        -install_name "@rpath/whisper.framework/Versions/Current/whisper" \
        -o "${dir}/whisper.dylib"
    xcrun strip -S "${dir}/whisper.dylib"
}

start=$(date +%s)
build_arch x86_64 "${X86_64_CMAKE_ARGS[@]}"
build_arch arm64

# 2. フレームワーク（上流 setup_framework_structure の macOS 版と同じ構造）
STAGE="${WHISPER_DIR}/build-xcf-framework"
FW="${STAGE}/whisper.framework"
rm -rf "${STAGE}"
mkdir -p "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules" "${FW}/Versions/A/Resources"
ln -sf A "${FW}/Versions/Current"
ln -sf Versions/Current/Headers "${FW}/Headers"
ln -sf Versions/Current/Modules "${FW}/Modules"
ln -sf Versions/Current/Resources "${FW}/Resources"
ln -sf Versions/Current/whisper "${FW}/whisper"

cp include/whisper.h include/parakeet.h \
    ggml/include/ggml.h ggml/include/ggml-alloc.h ggml/include/ggml-backend.h ggml/include/ggml-metal.h \
    ggml/include/ggml-cpu.h ggml/include/ggml-blas.h ggml/include/gguf.h \
    "${FW}/Versions/A/Headers/"

cat >"${FW}/Versions/A/Modules/module.modulemap" <<'EOF'
framework module whisper {
    header "whisper.h"
    header "parakeet.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

cat >"${FW}/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${MACOS_MIN_OS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>DTPlatformName</key>
    <string>macosx</string>
    <key>DTSDKName</key>
    <string>macosx${MACOS_MIN_OS_VERSION}</string>
</dict>
</plist>
EOF

lipo -create build-xcf-x86_64/whisper.dylib build-xcf-arm64/whisper.dylib -output "${FW}/Versions/A/whisper"

# 3. XCFramework（途中で失敗しても既存の成果物を壊さないよう、別名で作ってから差し替える）
TMP_OUTPUT="${OUTPUT}.tmp"
rm -rf "${TMP_OUTPUT}"
# xcodebuild はプラグインの読み込みに失敗して動かないことがある（Xcode 26.5 で DVTDownloads のシンボル不足。
# 直すには `xcodebuild -runFirstLaunch` が要る）。そのときは同じ構造（macos-arm64_x86_64 スライスだけ）を手で組む
if ! xcodebuild -create-xcframework -framework "${FW}" -output "${TMP_OUTPUT}"; then
    log "xcodebuild -create-xcframework が失敗した。XCFramework を手で組む"
    rm -rf "${TMP_OUTPUT}"
    mkdir -p "${TMP_OUTPUT}/macos-arm64_x86_64"
    ditto "${FW}" "${TMP_OUTPUT}/macos-arm64_x86_64/whisper.framework"
    cat >"${TMP_OUTPUT}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>whisper.framework/Versions/A/whisper</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>whisper.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
    plutil -lint "${TMP_OUTPUT}/Info.plist" >/dev/null
fi
rm -rf "${OUTPUT}"
mv "${TMP_OUTPUT}" "${OUTPUT}"

log "完了（$(( $(date +%s) - start )) 秒）: ${OUTPUT}"
lipo -info "${OUTPUT}/macos-arm64_x86_64/whisper.framework/Versions/A/whisper"
log "x86_64 スライスの AVX2/FMA は swift test --filter WhisperLinkTests（x86SliceHasAVX2）で確かめる"
