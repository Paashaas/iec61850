#!/bin/bash
#
# Linux variants are built in Docker (see docker-compose.yaml).
# macOS variants are built natively, because Mach-O cannot be produced from a Linux container without a macOS SDK / cctools cross toolchain.
# Windows is built locally via the zig drop-in C compiler.
#
# After every build, the resulting archive is validated to ensure (a) it is in the correct binary format for its target OS and (b) that the TLS support we depend on at the Go layer is actually compiled in.
# The script exits non-zero on any mismatch so we don't silently ship broken libraries again.
#
# Never pass CFLAGS on the make command line: it replaces every `CFLAGS +=` in the libiec61850 Makefile, including -DCONFIG_MMS_SUPPORT_TLS=1.

set -euo pipefail

# Versions
LIBIEC61850_VERSION=1.6.3
MBEDTLS_VERSION=3.6.0
WINPCAP_VERSION=4.1.2

REPO_DIR="./libiec61850-repo"
MBEDTLS_DIR="${REPO_DIR}/third_party/mbedtls/mbedtls-${MBEDTLS_VERSION}"
WINPCAP_ZIP="WpdPack_${WINPCAP_VERSION//./_}.zip"
BUILD_DIR="$(pwd)/build"
PLATFORMS="linux_amd64 linux_arm64 linux_armv7 windows_amd64"

# Download sources
echo "Downloading libiec61850 version ${LIBIEC61850_VERSION} from Paashaas/libiec61850..."
if [ -d "${REPO_DIR}" ]; then
    echo "Directory ${REPO_DIR} already exists. Skipping download."
else
    git clone --depth=1 -b "v${LIBIEC61850_VERSION}" https://github.com/Paashaas/libiec61850.git "${REPO_DIR}"
fi

if [ "$(git -C "${REPO_DIR}" describe --tags --exact-match 2>/dev/null)" != "v${LIBIEC61850_VERSION}" ]; then
    echo "ERROR: ${REPO_DIR} is not checked out at v${LIBIEC61850_VERSION}; remove it and run this script again" >&2
    exit 1
fi

# The Makefile enables R-GOOSE/R-SMV for WITH_MBEDTLS3 but, unlike CMake, never compiles src/r_session.
# Without it the GOOSE/SV objects reference undefined RSession_* symbols and the Go bindings fail to link.
if ! grep -q '^LIB_SOURCE_DIRS += src/r_session$' "${REPO_DIR}/Makefile"; then
    awk '{ print } /^LIB_SOURCE_DIRS \+= hal\/tls\/mbedtls3$/ { print "LIB_SOURCE_DIRS += src/r_session" }' \
        "${REPO_DIR}/Makefile" > "${REPO_DIR}/Makefile.tmp" && mv "${REPO_DIR}/Makefile.tmp" "${REPO_DIR}/Makefile"
fi

# The stack_config.h used by Makefile builds prints IED server debug output to stdout (CMake builds don't).
sed -i.bak 's/^#define DEBUG_IED_SERVER 1$/#define DEBUG_IED_SERVER 0/' "${REPO_DIR}/config/stack_config.h"
rm -f "${REPO_DIR}/config/stack_config.h.bak"

echo "Downloading mbedtls version ${MBEDTLS_VERSION}..."
if [ -d "${MBEDTLS_DIR}" ]; then
    echo "Directory ${MBEDTLS_DIR} already exists. Skipping download."
else
    git clone --depth=1 -b "v${MBEDTLS_VERSION}" https://github.com/Mbed-TLS/mbedtls.git "${MBEDTLS_DIR}"
fi

echo "Downloading Winpcap version ${WINPCAP_VERSION}..."
curl -fL "https://www.winpcap.org/install/bin/${WINPCAP_ZIP}" -o "${WINPCAP_ZIP}"
unzip -qo "${WINPCAP_ZIP}"
cp -r ./WpdPack/Lib "${REPO_DIR}/third_party/winpcap"
cp -r ./WpdPack/Include "${REPO_DIR}/third_party/winpcap"

# verify_archive <archive_path> <expected_format>
#   expected_format: "macho", "elf" or "coff"
#
# Fails the script if the archive is in the wrong binary format or if TLS support was not compiled in.
verify_archive() {
    local archive="$1"
    local expected="$2"

    if [ ! -f "${archive}" ]; then
        echo "ERROR: expected archive ${archive} was not produced" >&2
        exit 1
    fi

    local pattern
    case "${expected}" in
        macho) pattern="mach-o" ;;
        elf)   pattern="elf" ;;
        coff)  pattern="coff|pe-x86-64" ;;
        *)
            echo "ERROR: unknown expected format '${expected}'" >&2
            exit 1
            ;;
    esac

    # objdump reports the format of every member without extracting; macOS `ar -x` cannot read GNU-style (Linux/Windows) archives.
    # Every member is checked, so an archive that mixes Mach-O and ELF objects is rejected as well.
    local formats
    formats=$(objdump -f "${archive}" 2>/dev/null | grep 'file format' || true)
    if [ -z "${formats}" ] || grep -vqE "file format (${pattern})" <<< "${formats}"; then
        echo "ERROR: ${archive} does not contain only ${expected} objects" >&2
        exit 1
    fi

    # Captured first: `nm | grep -q` fails under pipefail when grep exits before nm has written everything.
    local symbols
    symbols=$(nm "${archive}" 2>/dev/null)

    # The Go bindings unconditionally reference these TLS symbols via cgo, so an archive without them will fail to link in any downstream project.
    if ! grep -qE " T _?TLSConfiguration_create$" <<< "${symbols}"; then
        echo "ERROR: ${archive} is missing TLSConfiguration_create — was the library built with WITH_MBEDTLS3=1?" >&2
        exit 1
    fi

    # The MMS layer only calls TLSSocket_create when CONFIG_MMS_SUPPORT_TLS=1 made it into CFLAGS.
    if ! grep -qE " U _?TLSSocket_create$" <<< "${symbols}"; then
        echo "ERROR: ${archive} was built without MMS TLS support (CONFIG_MMS_SUPPORT_TLS)" >&2
        exit 1
    fi

    if [ "${expected}" = "coff" ] && grep -qE " U (__ubsan_|__stack_chk_)" <<< "${symbols}"; then
        echo "ERROR: ${archive} references zig runtime symbols (__ubsan_*/__stack_chk_*) that MinGW GCC cannot resolve" >&2
        exit 1
    fi

    echo "OK: ${archive} (${expected}, TLS support present)"
}

rm -rf "${BUILD_DIR}"

# Build Linux variants in Docker
echo "Building Linux variants via docker compose..."
docker compose up --build

# Build macOS variants natively
build_darwin_native() {
    local target_dir="$1"   # e.g. darwin_armv8
    local arch="$2"         # e.g. arm64

    echo "Building ${target_dir} natively on $(uname -s)/$(uname -m)..."
    (
        cd "${REPO_DIR}"
        make clean >/dev/null
        # 12.0 is the oldest macOS Go supports; without it the objects require the macOS version of the build host.
        MACOSX_DEPLOYMENT_TARGET=12.0 make WITH_MBEDTLS3=1 \
             CC="cc -arch ${arch}" \
             INSTALL_PREFIX="${BUILD_DIR}/${target_dir}" \
             install
    )
}

if [ "$(uname -s)" = "Darwin" ]; then
    # Apple clang builds both architectures on Intel and Apple Silicon hosts.
    build_darwin_native darwin_armv8 arm64
    build_darwin_native darwin_amd64 x86_64
    PLATFORMS="${PLATFORMS} darwin_armv8 darwin_amd64"
else
    echo "WARNING: macOS targets cannot be built on $(uname -s); the darwin_*"\
         "archives currently in libiec61850/ will not be refreshed."\
         "Run build.sh on a macOS host (or in CI on a macos-* runner) to"\
         "rebuild them." >&2
fi

# Build Windows locally via zig.
# zig cc enables UBSan and stack protection for unoptimized builds; MinGW GCC has no runtime for either.
# The build gets its own zig cache because the shared one hands back objects compiled with the stack protector.
(cd "${REPO_DIR}" &&
    make TARGET=WIN64 clean >/dev/null &&
    ZIG_GLOBAL_CACHE_DIR="$(pwd)/build_win32/zig-cache" ZIG_LOCAL_CACHE_DIR="$(pwd)/build_win32/zig-cache" \
    make TARGET=WIN64 \
         CC="zig cc -target x86_64-windows-gnu -fno-sanitize=undefined -fno-stack-protector" \
         AR="zig ar" RANLIB="zig ranlib" \
         WITH_MBEDTLS3=1 \
         INSTALL_PREFIX="${BUILD_DIR}/windows_amd64" install
)
# GOOSE/SV on Windows need the wpcap import library at link time.
cp "${REPO_DIR}/third_party/winpcap/Lib/x64/wpcap.lib" "${BUILD_DIR}/windows_amd64/lib/libwpcap.a"

# Validate every produced archive before replacing anything in libiec61850/
echo "Validating produced archives..."
for platform in ${PLATFORMS}; do
    archive="${BUILD_DIR}/${platform}/lib/libiec61850.a"
    case "${platform}" in
        darwin_*)  verify_archive "${archive}" macho ;;
        linux_*)   verify_archive "${archive}" elf ;;
        windows_*) verify_archive "${archive}" coff ;;
    esac
done

# Stage produced libraries into ./libiec61850/<platform>
echo "Copying built libraries to libiec61850 directory..."
for platform in ${PLATFORMS}; do
    rm -rf "./libiec61850/${platform}"
    cp -R "${BUILD_DIR}/${platform}" "./libiec61850/${platform}"
    # Stub Go files so each platform directory is a valid package
    echo "package ${platform}" > "./libiec61850/${platform}/include/include.go"
    echo "package ${platform}" > "./libiec61850/${platform}/lib/lib.go"
done

echo "All archives built and validated successfully."
