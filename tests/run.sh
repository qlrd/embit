#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# SPDX-License-Identifier: MIT
# Run embit integration tests.
# Assumes poetry environment is already installed
# and activated.
#
# - Builds or restores bitcoind and elementsd under
#   $EMBIT_TEMP_DIR/binaries (shared cache under
#   $EMBIT_BIN_SRC_CACHE_ROOT/<os-arch>/...,
#   default /tmp/embit-test-src-bin-cache; set the
#   env var in CI to a workspace path —
#   actions/cache is unreliable under /tmp on
#   GitHub-hosted runners).
# - Cleans $EMBIT_TEMP_DIR/data before tests
#   (same idea as Floresta's run.sh).
#
# Flags:
#   --build              Force rebuild daemons.
#   --preserve-data-dir  Keep test data after run.
#   Any other arguments are forwarded to the Python
#   test entrypoint.
#
# Layout and cleanup mirror:
#   https://github.com/vinteumorg/Floresta/blob/
#     master/tests/run.sh
# Build logic is inlined here (no separate
# prepare.sh, no prebuilt downloads, no mktemp).

check_installed() {
    if ! command -v "$1" &>/dev/null; then
        echo "You must have $1 installed!"
        exit 1
    fi
}

check_installed_compiler() {
    if command -v gcc &>/dev/null \
        || command -v clang &>/dev/null; then
        return 0
    fi
    echo "You must have GCC or Clang installed!"
    exit 1
}

check_installed git
set -e

EMBIT_PROJ_DIR=$(git rev-parse --show-toplevel)
cd "$EMBIT_PROJ_DIR"

FORCE_BUILD=0
PRESERVE_DATA=false
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --build) FORCE_BUILD=1 ;;
        --preserve-data-dir) PRESERVE_DATA=true ;;
        *) TEST_ARGS+=("$arg") ;;
    esac
done

GIT_DESCRIBE=$(git describe --tags --always)

if [[ -z "${EMBIT_TEMP_DIR:-}" ]]; then
    export EMBIT_TEMP_DIR="/tmp/embit.${GIT_DESCRIBE}"
fi

mkdir -p "$EMBIT_TEMP_DIR/binaries"

# Defaults match tests/integration/daemon-versions.env
# (used for CI cache keys).
BITCOIN_REV="${BITCOIN_REVISION:-30.2}"
BITCOIN_REV="${BITCOIN_REV#v}"
ELEMENTS_REV="${ELEMENTS_REVISION:-23.3.2}"

HOST_ID="$(uname -s)-$(uname -m)"
if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
    # GitHub Actions: cache under workspace so
    # actions/cache can persist it across runs.
    BIN_CACHE_ROOT="${GITHUB_WORKSPACE}/.cache/embit-test-src-bin-cache"
else
    BIN_CACHE_ROOT="${EMBIT_BIN_SRC_CACHE_ROOT:-/tmp/embit-test-src-bin-cache}"
fi
BIN_CACHE="${BIN_CACHE_ROOT}/${HOST_ID}"
BTC_CACHE="${BIN_CACHE}/bitcoin-v${BITCOIN_REV}/bitcoind"
ELM_CACHE="${BIN_CACHE}/elements-${ELEMENTS_REV}/elementsd"

if [[ -n "${BUILD_BITCOIND_NPROCS:-}" ]]; then
    BUILD_PARALLEL="$BUILD_BITCOIND_NPROCS"
elif command -v nproc >/dev/null 2>&1; then
    BUILD_PARALLEL="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
    BUILD_PARALLEL="$(sysctl -n hw.ncpu)"
else
    BUILD_PARALLEL="${BUILD_PARALLEL:-4}"
fi

copy_cached_binary() {
    [ -f "$1" ] || return 1
    echo "Restoring $3 from cache: $1"
    cp -f "$1" "$2"
    chmod +x "$2"
}

update_binary_cache() {
    mkdir -p "$(dirname "$2")"
    cp -f "$1" "$2"
    chmod +x "$2"
}

# Args: display_name dest_path cache_path build_fn
ensure_daemon_binary() {
    if [ "$FORCE_BUILD" -eq 1 ]; then
        "$4"
        update_binary_cache "$2" "$3"
    elif [ -f "$2" ]; then
        echo "$1 already at $EMBIT_TEMP_DIR, skip"
    elif copy_cached_binary "$3" "$2" "$1"; then
        :
    else
        "$4"
        update_binary_cache "$2" "$3"
    fi
}

clone_and_checkout_tag() {
    local url=$1 dir=$2 tag=$3 label=$4
    git clone "$url" "$dir"
    cd "$dir" || exit 1
    if ! git rev-parse -q --verify \
        "refs/tags/${tag}" >/dev/null; then
        echo "${label} '${tag}' is not a valid tag."
        exit 1
    fi
    git checkout "$tag"
}

check_berkeley_db() {
    if command -v pkg-config >/dev/null 2>&1; then
        for _bdb_pc in libdb libdb-4.8 db48; do
            if pkg-config --exists \
                "${_bdb_pc}" 2>/dev/null; then
                return 0
            fi
        done
    fi
    for _bdb_prefix in \
        "/opt/homebrew/opt/berkeley-db@4" \
        "/usr/local/opt/berkeley-db@4" \
        "/opt/homebrew/opt/berkeley-db" \
        "/usr/local/opt/berkeley-db"; do
        if [ -f "${_bdb_prefix}/include/db.h" ]; then
            return 0
        fi
    done
    for _db_h in \
        /usr/include/db.h \
        /usr/include/db4/db.h \
        /usr/include/db4.8/db.h \
        /usr/include/db5.3/db.h; do
        if [ -f "${_db_h}" ]; then
            return 0
        fi
    done
    echo "elementsd needs Berkeley DB dev files."
    echo "  macOS:  brew install berkeley-db@4"
    echo "  Debian: sudo apt install libdb-dev"
    echo "  Fedora: sudo dnf install libdb-devel"
    exit 1
}

# Inspired by Floresta's build_bitcoind_from_source
# (cmake vs autotools split), without disposable
# build dirs or prebuilt tarballs.
build_core() {
    rm -rf "$EMBIT_TEMP_DIR/binaries/build"
    mkdir -p "$EMBIT_TEMP_DIR/binaries/build"
    cd "$EMBIT_TEMP_DIR/binaries/build" || exit 1

    echo "Building Bitcoin Core..."
    clone_and_checkout_tag \
        https://github.com/bitcoin/bitcoin \
        bitcoin "v${BITCOIN_REV}" bitcoin

    if [[ "$BITCOIN_REV" =~ ^([0-9]+) ]]; then
        major_version="${BASH_REMATCH[1]}"
    else
        major_version=999
    fi
    if [ "$major_version" -ge 29 ]; then
        cmake -S . -B build \
            -DENABLE_IPC=OFF \
            -DBUILD_CLI=OFF \
            -DBUILD_TESTS=OFF \
            -DENABLE_WALLET=ON \
            -DCMAKE_BUILD_TYPE=MinSizeRel \
            -DENABLE_EXTERNAL_SIGNER=OFF \
            -DINSTALL_MAN=OFF
        cmake --build build \
            --target bitcoind \
            -j"${BUILD_PARALLEL}"
        BTC_BIN="build/bitcoin/build/bin/bitcoind"
    else
        ./autogen.sh
        ./configure \
            --without-gui \
            --disable-tests \
            --disable-bench
        make -j"${BUILD_PARALLEL}"
        BTC_BIN="build/bitcoin/src/bitcoind"
    fi
    mv "$EMBIT_TEMP_DIR/binaries/${BTC_BIN}" \
        "$EMBIT_TEMP_DIR/binaries/bitcoind"

    rm -rf "$EMBIT_TEMP_DIR/binaries/build"
}

build_elements() {
    check_berkeley_db

    rm -rf "$EMBIT_TEMP_DIR/binaries/build"
    mkdir -p "$EMBIT_TEMP_DIR/binaries/build"
    cd "$EMBIT_TEMP_DIR/binaries/build"

    echo "Building Elements Core..."
    clone_and_checkout_tag \
        https://github.com/ElementsProject/elements \
        elements "elements-${ELEMENTS_REV}" elements

    ./autogen.sh
    ./configure \
        --disable-tests \
        --disable-bench
    make -j"${BUILD_PARALLEL}"
    ELM_BIN="build/elements/src/elementsd"
    mv "$EMBIT_TEMP_DIR/binaries/${ELM_BIN}" \
        "$EMBIT_TEMP_DIR/binaries/elementsd"
    rm -rf "$EMBIT_TEMP_DIR/binaries/build"
}

# Skip toolchain checks when cache is populated.
if [[ "$FORCE_BUILD" -eq 0 ]] \
    && [[ -f "$BTC_CACHE" ]] \
    && [[ -f "$ELM_CACHE" ]]; then
    echo "Cached daemons present; skipping build."
else
    check_installed_compiler
    check_installed make
    check_installed cmake
    check_installed autoconf
    check_installed automake
    check_installed libtool
fi

DEST="$EMBIT_TEMP_DIR/binaries"
ensure_daemon_binary \
    Bitcoind "$DEST/bitcoind" "$BTC_CACHE" build_core
ensure_daemon_binary \
    Elementsd "$DEST/elementsd" "$ELM_CACHE" build_elements

echo "Binaries at $EMBIT_TEMP_DIR/binaries"

# Clean data before running tests
echo "Cleaning data at $EMBIT_TEMP_DIR/data"
rm -rf "$EMBIT_TEMP_DIR/data"

RUN="tests/integration/run_tests.py"
echo "Running integration tests: python ${RUN}"
python "$RUN" "${TEST_ARGS[@]}" || exit 1

echo "Tests passed"
if [ "$PRESERVE_DATA" = false ]; then
    echo "Cleaning $EMBIT_TEMP_DIR/data"
    rm -rf "$EMBIT_TEMP_DIR/data"
fi

exit 0
