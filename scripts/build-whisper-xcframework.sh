#!/usr/bin/env bash
# whisper.cpp（tools/whisper.cpp）と llama.cpp（tools/llama.cpp）を、llama.cpp の ggml 1 つだけでビルドし、
# 両方を入れた macOS 用の tools/whisper.xcframework を作る（フレームワーク名・モジュール名は今までどおり whisper）。
#
# 使い方: scripts/build-whisper-xcframework.sh [--force]
#   --force   tools/whisper.xcframework が今の版でも作り直す（既定は、今の版で作成済みならスキップ。
#             版が違う・版の記録が無い古い成果物は自動で作り直す）
#   JOBS      ビルドの並列数（既定: 論理 CPU 数）
#
# 版はここで固定する（違うコミットの checkout があれば止まる）:
#   - whisper.cpp v1.9.5（WHISPER_COMMIT）
#   - llama.cpp b12359（LLAMA_COMMIT。Homebrew の llama.cpp 1.0.0 と同じ）。この ggml を whisper.cpp も使う。
#     PLaMo 3 Translate には 2026-11-05 以降の ggml（#30206 YaRN の truncate=false）と #30045（tokenizer）が要る。
#     whisper.cpp v1.9.5 同梱の ggml にはまだ入っていない（docs/superpowers/research/2026-11-14-plamo-3-translate-spike.md 2.1 節）
#
# ggml を共有する仕組み: 小さな親 CMake プロジェクトで llama.cpp → whisper.cpp の順に add_subdirectory する。
# whisper.cpp の CMakeLists は ggml のターゲットがすでにあれば自前の ggml を足さない（「added by a parent CMakeLists.txt」）。
# 静的ライブラリを 1 つの dylib にまとめるので、ggml のシンボル・Metal デバイス・バックエンド登録は 1 つだけになる。
#
# 公式の whisper-b5454-xcframework.zip の x86_64 スライスは AVX/AVX2/FMA/F16C なしでビルドされていて
# Intel Mac で約 7 倍遅い（docs/superpowers/research/2026-10-24-spike-results.md 項目 8）。そのため:
#   - x86_64: 上流の macOS 用フラグ + -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
#             （GGML_NATIVE=ON にしない。ビルドした Mac の CPU、たとえば AVX-512 に依存させない）
#   - arm64:  上流の macOS 用フラグのまま（Metal・Core ML）
# を別々にビルドし（x86 専用の -m フラグは universal ビルドを壊す）、lipo で 1 つのフレームワークにまとめる。
set -euo pipefail

FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=1 ;;
        -h|--help) sed -n "2,24p" "$0"; exit 0 ;;
        *) echo "不明な引数: ${arg}（使えるのは --force）" >&2; exit 64 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${ROOT}/tools/whisper.cpp"
WHISPER_TAG="v1.9.5"      # = b5454。scripts/setup-whisper.sh と同じタグ
WHISPER_COMMIT="d1be6fde11ac6e0407606b4e42fe72d34add8037"  # WHISPER_TAG が指すコミット
LLAMA_DIR="${ROOT}/tools/llama.cpp"
LLAMA_TAG="b12359"        # Homebrew の llama.cpp 1.0.0（2026-11-13）
LLAMA_COMMIT="b1b770d90d94cad9e9ea5b993bdbc383a522fb28"    # LLAMA_TAG が指すコミット
BUILD_ROOT="${ROOT}/tools/native-build"
OUTPUT="${ROOT}/tools/whisper.xcframework"
STAMP_NAME="AutoNoteBuild.txt"   # 成果物の版の記録（xcframework の直下。古い成果物を見分けて作り直すため）
STAMP="whisper.cpp=${WHISPER_COMMIT} llama.cpp=${LLAMA_COMMIT} layout=2"
MACOS_MIN_OS_VERSION=26.0
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

log() { echo "[build-whisper-xcframework] $*"; }

if [[ "${FORCE}" -eq 0 && -f "${OUTPUT}/Info.plist" ]]; then
    if [[ "$(cat "${OUTPUT}/${STAMP_NAME}" 2>/dev/null)" == "${STAMP}" ]]; then
        log "${OUTPUT} は今の版で作成済み。スキップ（作り直すなら --force）"
        exit 0
    fi
    log "${OUTPUT} は古い版（${STAMP_NAME} が違う・無い）。作り直す"
fi

for tool in cmake xcodebuild libtool lipo git; do
    command -v "${tool}" >/dev/null || { echo "${tool} が見つからない" >&2; exit 1; }
done

# 1. ソース。無ければ clone する。既存の checkout が別のコミットなら止まる（利用者の作業があるかもしれないので checkout し直さない）
fetch_source() {
    local dir="$1" url="$2" tag="$3" commit="$4" name
    name="$(basename "${dir}")"
    if [[ ! -f "${dir}/CMakeLists.txt" ]]; then
        log "clone: ${url} ${tag}"
        mkdir -p "$(dirname "${dir}")"
        git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" "${url}" "${dir}"
    fi
    local head
    head="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [[ "${head}" != "${commit}" ]]; then
        echo "tools/${name} のコミットが ${head} で、期待する ${commit}（${tag}）と違う。" >&2
        echo "git -C tools/${name} fetch --depth 1 origin tag ${tag} && git -C tools/${name} checkout ${commit} で合わせるか、tools/${name} を消して再実行する" >&2
        exit 1
    fi
}
fetch_source "${WHISPER_DIR}" https://github.com/ggml-org/whisper.cpp "${WHISPER_TAG}" "${WHISPER_COMMIT}"
fetch_source "${LLAMA_DIR}" https://github.com/ggml-org/llama.cpp "${LLAMA_TAG}" "${LLAMA_COMMIT}"

# 親プロジェクト（llama.cpp が ggml と llama を、whisper.cpp がその ggml を使って whisper を作る）
SUPER="${BUILD_ROOT}/superbuild"
mkdir -p "${SUPER}"
cat >"${SUPER}/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.18)
project(autonote_native C CXX)
add_subdirectory("${LLAMA_DIR}" llama)
add_subdirectory("${WHISPER_DIR}" whisper)
EOF

GENERATOR=()
command -v ninja >/dev/null && GENERATOR=(-G Ninja)

# 上流 build-xcframework.sh の macOS 用オプション（Xcode 用の属性とデバッグ情報 -g は除く）
COMMON_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN_OS_VERSION}"
    -DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -DBUILD_SHARED_LIBS=OFF
    # whisper.cpp
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DWHISPER_COREML=ON
    -DWHISPER_COREML_ALLOW_FALLBACK=ON
    # llama.cpp（ライブラリだけ。HTTPS・共通ユーティリティ・ツール類は使わない）
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_UI=OFF
    -DLLAMA_OPENSSL=OFF
    # ggml（llama.cpp 側の 1 つだけ）
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DGGML_BACKEND_DL=OFF
)
X86_64_CMAKE_ARGS=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)

# build_arch <arch> <追加の CMake 引数...>: tools/native-build/<arch>/ に静的ライブラリを作り、1 つの dylib にまとめる
build_arch() {
    local arch="$1"; shift
    local dir="${BUILD_ROOT}/${arch}"
    log "${arch} をビルド（${dir}/、-j${JOBS}）"
    rm -rf "${dir}"
    cmake -B "${dir}" "${GENERATOR[@]}" "${COMMON_CMAKE_ARGS[@]}" -DCMAKE_OSX_ARCHITECTURES="${arch}" "$@" -S "${SUPER}"
    cmake --build "${dir}" --config Release -j "${JOBS}" --target whisper parakeet llama

    # ggml は llama/ggml/ の 1 組だけ（whisper/ggml/ はできない。できていたら二重リンクになるので止まる）
    if [[ -d "${dir}/whisper/ggml" ]]; then
        echo "whisper.cpp が自前の ggml をビルドした（${dir}/whisper/ggml）。ggml が二重になる" >&2
        exit 1
    fi
    local libs=(
        "${dir}/whisper/src/libwhisper.a"
        "${dir}/whisper/src/libparakeet.a"
        "${dir}/whisper/src/libwhisper.coreml.a"
        "${dir}/llama/src/libllama.a"
        "${dir}/llama/ggml/src/libggml.a"
        "${dir}/llama/ggml/src/libggml-base.a"
        "${dir}/llama/ggml/src/libggml-cpu.a"
        "${dir}/llama/ggml/src/ggml-metal/libggml-metal.a"
        "${dir}/llama/ggml/src/ggml-blas/libggml-blas.a"
    )
    local lib
    for lib in "${libs[@]}"; do
        [[ -f "${lib}" ]] || { echo "静的ライブラリが無い: ${lib}" >&2; exit 1; }
    done
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
STAGE="${BUILD_ROOT}/framework"
FW="${STAGE}/whisper.framework"
rm -rf "${STAGE}"
mkdir -p "${FW}/Versions/A/Headers" "${FW}/Versions/A/Modules" "${FW}/Versions/A/Resources"
ln -sf A "${FW}/Versions/Current"
ln -sf Versions/Current/Headers "${FW}/Headers"
ln -sf Versions/Current/Modules "${FW}/Modules"
ln -sf Versions/Current/Resources "${FW}/Resources"
ln -sf Versions/Current/whisper "${FW}/whisper"

GGML_INCLUDE="${LLAMA_DIR}/ggml/include"
cp "${WHISPER_DIR}/include/whisper.h" "${WHISPER_DIR}/include/parakeet.h" \
    "${LLAMA_DIR}/include/llama.h" \
    "${GGML_INCLUDE}/ggml.h" "${GGML_INCLUDE}/ggml-alloc.h" "${GGML_INCLUDE}/ggml-backend.h" \
    "${GGML_INCLUDE}/ggml-metal.h" "${GGML_INCLUDE}/ggml-cpu.h" "${GGML_INCLUDE}/ggml-blas.h" \
    "${GGML_INCLUDE}/ggml-opt.h" "${GGML_INCLUDE}/gguf.h" \
    "${FW}/Versions/A/Headers/"

cat >"${FW}/Versions/A/Modules/module.modulemap" <<'EOF'
framework module whisper {
    header "whisper.h"
    header "parakeet.h"
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "ggml-opt.h"
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

lipo -create "${BUILD_ROOT}/x86_64/whisper.dylib" "${BUILD_ROOT}/arm64/whisper.dylib" -output "${FW}/Versions/A/whisper"

# 3. XCFramework（途中で失敗しても既存の成果物を壊さないよう、別名で作ってから差し替える）
TMP_OUTPUT="${OUTPUT}.tmp"
rm -rf "${TMP_OUTPUT}"
# xcodebuild はプラグインの読み込みに失敗して動かないことがある（Xcode 26.5 で DVTDownloads のシンボル不足。
# 直すには `xcodebuild -runFirstLaunch` が要る。Command Line Tools だけの Mac でも失敗する）。
# そのときは同じ構造（macos-arm64_x86_64 スライスだけ）を手で組む
if ! xcodebuild -create-xcframework -framework "${FW}" -output "${TMP_OUTPUT}" 2>/dev/null; then
    log "xcodebuild -create-xcframework が使えない。XCFramework を手で組む"
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
echo "${STAMP}" >"${TMP_OUTPUT}/${STAMP_NAME}"
rm -rf "${OUTPUT}"
mv "${TMP_OUTPUT}" "${OUTPUT}"

log "完了（$(( $(date +%s) - start )) 秒）: ${OUTPUT}"
lipo -info "${OUTPUT}/macos-arm64_x86_64/whisper.framework/Versions/A/whisper"
log "x86_64 スライスの AVX2/FMA は swift test --filter WhisperLinkTests（x86SliceHasAVX2）で確かめる"
