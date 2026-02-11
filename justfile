#!/usr/bin/env just --justfile

main_crate := 'maplibre_native'
just_cmd := if os() == 'windows' {'just'} else {just_executable()}

# if running in CI, treat warnings as errors by setting RUSTFLAGS and RUSTDOCFLAGS to '-D warnings' unless they are already set
# Use `CI=true just ci-test` to run the same tests as in GitHub CI.
# Use `just env-info` to see the current values of RUSTFLAGS and RUSTDOCFLAGS
ci_mode := if env('CI', '') != '' {'1'} else {''}
export RUSTFLAGS := env('RUSTFLAGS', if ci_mode == '1' {'-D warnings'} else {''})
export RUSTDOCFLAGS := env('RUSTDOCFLAGS', if ci_mode == '1' {'-D warnings'} else {''})
export RUST_BACKTRACE := env('RUST_BACKTRACE', if ci_mode == '1' {'1'} else {''})

@_default:
    "{{just_cmd}}" --list

# Build the project
build backend='vulkan':
    cargo build --workspace --features {{backend}} --all-targets

# Run integration tests and save its output as the new expected output
bless *args:  (cargo-install 'cargo-insta')
    cargo insta test --accept {{args}}

# Quick compile without building a binary
check:
    cargo check --workspace --all-targets

# Lint the project
ci-lint: env-info test-fmt clippy

# Run all tests as expected by CI
ci-test backend: env-info (build backend) (test backend) (test-doc backend) && assert-git-is-clean

# Run minimal subset of tests to ensure compatibility with MSRV
ci-test-msrv backend: (ci-test backend)  # for now, same as ci-test

# Clean all build artifacts
clean:
    cargo clean
    rm -f Cargo.lock

# Run cargo clippy to lint the code
clippy *args:
    cargo clippy --workspace --all-targets {{args}}

# Build and open code documentation
docs backend *args='--open':
    DOCS_RS=1 cargo doc --no-deps {{args}} --workspace --features {{backend}}

# Print environment info
env-info:
    @echo "Running {{if ci_mode == '1' {'in CI mode'} else {'in dev mode'} }} on {{os()}} / {{arch()}}"
    echo "PWD $(pwd)"
    "{{just_cmd}}" --version
    rustc --version
    cargo --version
    rustup --version
    @echo "RUSTFLAGS='$RUSTFLAGS'"
    @echo "RUSTDOCFLAGS='$RUSTDOCFLAGS'"
    @echo "RUST_BACKTRACE='$RUST_BACKTRACE'"

# Reformat all code `cargo fmt`. If nightly is available, use it for better results
fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    if (rustup toolchain list | grep nightly && rustup component list --toolchain nightly | grep rustfmt) &> /dev/null; then
        echo 'Reformatting Rust code using nightly Rust fmt to sort imports'
        cargo +nightly fmt --all -- --config imports_granularity=Module,group_imports=StdExternalCrate
    else
        echo 'Reformatting Rust with the stable cargo fmt.  Install nightly with `rustup install nightly` for better results'
        cargo fmt --all
    fi

# Reformat all Cargo.toml files using cargo-sort
fmt-toml *args: (cargo-install 'cargo-sort')
    cargo sort --workspace --order package,lib,bin,bench,features,dependencies,build-dependencies,dev-dependencies {{args}}

# Get any package's field from the metadata
get-crate-field field package=main_crate:  (assert-cmd 'jq')
    @cargo metadata --format-version 1 | jq -e -r '.packages | map(select(.name == "{{package}}")) | first | .{{field}} // error("Field \"{{field}}\" is missing in Cargo.toml for package {{package}}")'

# Get the minimum supported Rust version (MSRV) for the crate
get-msrv package=main_crate:  (get-crate-field 'rust_version' package)

# Install Linux dependencies (Ubuntu/Debian). Supports 'vulkan' and 'opengl' backends.
[linux]
install-dependencies backend='vulkan':
    sudo apt-get update
    sudo apt-get install -y \
      {{if backend == 'opengl' {'libgl1-mesa-dev libglu1-mesa-dev libegl1-mesa-dev'} else if backend == 'vulkan' {'mesa-vulkan-drivers glslang-dev spirv-tools'} else {''} }} \
      build-essential \
      libcurl4-openssl-dev \
      libglfw3-dev \
      libjpeg-dev \
      libpng-dev \
      libuv1-dev \
      libwebp-dev \
      libz-dev

# Install macOS dependencies via Homebrew
[macos]
install-dependencies backend='vulkan':
    brew install \
        {{if backend == 'vulkan' {'molten-vk vulkan-headers'} else {''} }} \
        curl \
        glfw \
        libuv \
        zlib

# Install Windows dependencies
#
# Note: For now, we rely on the precompiled core artefacts and the toolchain that comes with
# the GitHub Actions windows runner. If additional system libraries are required in the future,
# add them here.
[windows]
install-dependencies backend='vulkan':
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Installing Windows dependencies via vcpkg (backend={{backend}})"

    # Use a pinned vcpkg version in CI to match the ABI expectations of the
    # precompiled maplibre-native core library (notably libpng).
    VCPKG_PINNED_TAG="${VCPKG_PINNED_TAG:-2025.04.09}"

    # `VCPKG_ROOT` is treated as an explicit override (useful for local dev).
    # On GitHub Actions, avoid the runner-preinstalled vcpkg ports tree so we get
    # deterministic, compatible dependency versions.
    VCPKG_ROOT_RAW="${VCPKG_ROOT:-}"
    if [[ -z "$VCPKG_ROOT_RAW" ]]; then
      if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        VCPKG_ROOT_RAW="$(pwd)/target/vcpkg"
      else
        VCPKG_ROOT_RAW="${VCPKG_INSTALLATION_ROOT:-}"
        if [[ -z "$VCPKG_ROOT_RAW" ]]; then
          VCPKG_ROOT_RAW="$(pwd)/target/vcpkg"
        fi
      fi
    fi

    # Normalize to a forward-slash Windows path (e.g. C:/vcpkg) for rustc link-search.
    if command -v cygpath >/dev/null 2>&1; then
      VCPKG_ROOT_NORM="$(cygpath -m "$VCPKG_ROOT_RAW")"
      VCPKG_ROOT_UNIX="$(cygpath -u "$VCPKG_ROOT_RAW")"
    else
      VCPKG_ROOT_NORM="$VCPKG_ROOT_RAW"
      VCPKG_ROOT_UNIX="$VCPKG_ROOT_RAW"
    fi

    if [[ ! -f "$VCPKG_ROOT_UNIX/vcpkg.exe" && ! -f "$VCPKG_ROOT_UNIX/vcpkg" ]]; then
      echo "Bootstrapping vcpkg into $VCPKG_ROOT_UNIX"
      # Safety: never `rm -rf` arbitrary directories when bootstrapping.
      #
      # In CI we bootstrap into a repo-local cache directory (`target/vcpkg`).
      # For local dev, users may have `VCPKG_ROOT`/`VCPKG_INSTALLATION_ROOT` set to a
      # shared system location; deleting that would be catastrophic.
      SAFE_VCPKG_DIR="$(pwd)/target/vcpkg"
      if [[ -e "$VCPKG_ROOT_UNIX" && ! -d "$VCPKG_ROOT_UNIX" ]]; then
        echo "VCPKG root exists but is not a directory: $VCPKG_ROOT_UNIX" >&2
        exit 1
      fi
      if [[ -d "$VCPKG_ROOT_UNIX" && -n "$(ls -A "$VCPKG_ROOT_UNIX" 2>/dev/null)" ]]; then
        if [[ "$VCPKG_ROOT_UNIX" != "$SAFE_VCPKG_DIR" ]]; then
          echo "Refusing to delete non-empty vcpkg dir: $VCPKG_ROOT_UNIX" >&2
          echo "Unset VCPKG_ROOT/VCPKG_INSTALLATION_ROOT to use $SAFE_VCPKG_DIR, or point it to an existing vcpkg checkout." >&2
          exit 1
        fi
        rm -rf "$VCPKG_ROOT_UNIX"
      fi
      git clone --depth 1 --branch "$VCPKG_PINNED_TAG" https://github.com/microsoft/vcpkg "$VCPKG_ROOT_UNIX"
      # In Git Bash (MSYS), arguments that start with `/` can be treated as paths.
      # Disable argument path conversion so `cmd.exe /c ...` is passed through unchanged.
      (cd "$VCPKG_ROOT_UNIX" && MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 cmd.exe /c bootstrap-vcpkg.bat)
    fi

    VCPKG_EXE="$VCPKG_ROOT_UNIX/vcpkg.exe"
    if [[ ! -f "$VCPKG_EXE" ]]; then
      VCPKG_EXE="$VCPKG_ROOT_UNIX/vcpkg"
    fi
    if [[ ! -f "$VCPKG_EXE" ]]; then
      echo "vcpkg executable not found after bootstrap under: $VCPKG_ROOT_UNIX" >&2
      ls -la "$VCPKG_ROOT_UNIX" >&2 || true
      exit 1
    fi

    # vcpkg may intermittently fail fetching GitHub archives with HTTP 5xx.
    # Pre-seed the known registry tarballs into VCPKG_DOWNLOADS and use codeload
    # as a fallback endpoint (same archive bytes, different host).
    export VCPKG_DOWNLOADS="$VCPKG_ROOT_UNIX/downloads"
    mkdir -p "$VCPKG_DOWNLOADS"
    preseed_vcpkg_github_archive() {
      local repo="$1"
      local ref="$2"
      local archive_name
      local archive_path
      local primary_url
      local fallback_url
      local tmp_path

      archive_name="${repo//\//-}-${ref}.tar.gz"
      archive_path="$VCPKG_DOWNLOADS/$archive_name"
      primary_url="https://github.com/${repo}/archive/${ref}.tar.gz"
      fallback_url="https://codeload.github.com/${repo}/tar.gz/${ref}"
      tmp_path="${archive_path}.tmp"

      if [[ -f "$archive_path" ]]; then
        echo "Using cached vcpkg distfile: $archive_name"
        return 0
      fi

      rm -f "$tmp_path"
      echo "Pre-seeding vcpkg distfile: $archive_name"
      if curl -L --retry 20 --retry-all-errors --retry-delay 3 --silent --show-error --fail \
        "$primary_url" -o "$tmp_path"; then
        mv -f "$tmp_path" "$archive_path"
        return 0
      fi
      echo "Primary URL failed, retrying via codeload: $fallback_url"
      if curl -L --retry 20 --retry-all-errors --retry-delay 3 --silent --show-error --fail \
        "$fallback_url" -o "$tmp_path"; then
        mv -f "$tmp_path" "$archive_path"
        return 0
      fi

      rm -f "$tmp_path"
      echo "Warning: failed to pre-seed $archive_name; vcpkg will fetch it directly" >&2
      return 1
    }
    preseed_vcpkg_github_archive "KhronosGroup/EGL-Registry" "7db3005d4c2cb439f129a0adc931f3274f9019e6" || true
    preseed_vcpkg_github_archive "KhronosGroup/OpenGL-Registry" "3530768138c5ba3dfbb2c43c830493f632f7ea33" || true

    # These are required by the precompiled maplibre-native core library on Windows.
    #
    # vcpkg occasionally fails to fetch upstream tarballs with transient HTTP 5xx errors.
    # Retry a few times to make CI resilient.
    VCPKG_TRIPLET="x64-windows"
    VCPKG_PACKAGES=(
      libuv
      sqlite3
      zlib
      curl
      angle
      libpng
      libjpeg-turbo
      libwebp
    )
    if [[ "{{backend}}" == "vulkan" ]]; then
      # Vulkan backend needs loader + shader toolchain libs used by the precompiled core.
      VCPKG_PACKAGES+=(
        vulkan-loader
        glslang
        spirv-tools
      )
    fi
    for attempt in 1 2 3 4 5; do
      echo "vcpkg install attempt $attempt/5"
      if "$VCPKG_EXE" install "${VCPKG_PACKAGES[@]}" --triplet "$VCPKG_TRIPLET"; then
        break
      fi
      if [[ "$attempt" == "5" ]]; then
        echo "vcpkg install failed after 5 attempts" >&2
        exit 1
      fi
      sleep 10
    done

    # Helpful version diagnostics in CI logs.
    "$VCPKG_EXE" list --triplet "$VCPKG_TRIPLET" | grep -E '^(libpng|zlib|sqlite3) ' || true

    # Persist to subsequent CI steps if running inside GitHub Actions.
    if [[ -n "${GITHUB_ENV:-}" ]]; then
      echo "VCPKG_ROOT=$VCPKG_ROOT_NORM" >> "$GITHUB_ENV"
      echo "VCPKG_DEFAULT_TRIPLET=x64-windows" >> "$GITHUB_ENV"
    fi

    # Ensure runtime DLLs (ANGLE/curl/png/jpeg/webp/etc.) are on PATH in GitHub Actions.
    if [[ -n "${GITHUB_PATH:-}" ]]; then
      echo "$VCPKG_ROOT_NORM/installed/x64-windows/bin" >> "$GITHUB_PATH"
    fi

    if [[ "{{backend}}" == "vulkan" ]]; then
      # Windows runners often do not have a Vulkan ICD installed. Provide a
      # software Vulkan driver (Mesa lavapipe) and point the loader at its ICD file.
      #
      # We pin the Mesa-dist-win version for deterministic CI.
      MESA_VER="25.3.5"
      MESA_FILE="mesa3d-$MESA_VER-release-msvc.7z"
      MESA_URL="https://github.com/pal1000/mesa-dist-win/releases/download/$MESA_VER/$MESA_FILE"

      MESA_DIR_UNIX="$(pwd)/target/mesa-dist-win/$MESA_VER"
      MESA_EXTRACT_UNIX="$MESA_DIR_UNIX/extract"
      mkdir -p "$MESA_DIR_UNIX"

      if [[ ! -f "$MESA_DIR_UNIX/$MESA_FILE" ]]; then
        echo "Downloading Mesa software Vulkan ICD from $MESA_URL"
        curl -L --retry 10 --retry-connrefused --silent --show-error --fail \
          "$MESA_URL" -o "$MESA_DIR_UNIX/$MESA_FILE"
      fi

      if [[ ! -d "$MESA_EXTRACT_UNIX/x64" ]]; then
        if ! command -v 7z >/dev/null 2>&1; then
          echo "7z not found; required to extract $MESA_FILE" >&2
          exit 1
        fi
        mkdir -p "$MESA_EXTRACT_UNIX"
        7z x "$MESA_DIR_UNIX/$MESA_FILE" "-o$MESA_EXTRACT_UNIX" >/dev/null
      fi

      VK_ICD_UNIX="$MESA_EXTRACT_UNIX/x64/lvp_icd.x86_64.json"
      if [[ ! -f "$VK_ICD_UNIX" ]]; then
        echo "Mesa Vulkan ICD manifest not found at expected path: $VK_ICD_UNIX" >&2
        find "$MESA_EXTRACT_UNIX" -maxdepth 5 -type f -iname '*icd*.json' -print >&2 || true
        exit 1
      fi

      VK_ICD="$VK_ICD_UNIX"
      MESA_BIN_PATH="$MESA_EXTRACT_UNIX/x64"
      if command -v cygpath >/dev/null 2>&1; then
        VK_ICD="$(cygpath -w "$VK_ICD_UNIX")"
        MESA_BIN_PATH="$(cygpath -w "$MESA_EXTRACT_UNIX/x64")"
      fi
      echo "Using Vulkan ICD manifest: $VK_ICD"

      if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "VK_ICD_FILENAMES=$VK_ICD" >> "$GITHUB_ENV"
        # Newer Vulkan loaders prefer VK_DRIVER_FILES.
        echo "VK_DRIVER_FILES=$VK_ICD" >> "$GITHUB_ENV"
      fi
      if [[ -n "${GITHUB_PATH:-}" ]]; then
        echo "$MESA_BIN_PATH" >> "$GITHUB_PATH"
      fi
    fi

    # ICU (required by mbgl::BiDi) is not currently provided as a compatible prebuilt dependency
    # for the published Windows core artefacts. Build ICU 61.2 from source with MSVC and link it.
    ICU_VER="61_2"
    ICU_TAG="${ICU_VER//_/-}"
    ICU_WORK_UNIX="$(pwd)/target/icu4c-$ICU_VER"
    ICU_SRC_UNIX="$ICU_WORK_UNIX/icu/source"
    ICU_ALT_UNIX="$ICU_WORK_UNIX/icu"

    find_icu_lib() {
      # Find the first import library produced by the ICU build.
      #
      # This is more reliable than checking for `lib64/` because the exact output
      # layout can vary across runners and build systems.
      find "$ICU_WORK_UNIX" -maxdepth 10 -type f \
        \( -iname 'icudt*.lib' -o -iname 'icuuc*.lib' -o -iname 'icuin*.lib' \) \
        -print -quit 2>/dev/null || true
    }

    icu_root_from_artifact() {
      local artifact="$1"
      local dir
      dir="$(dirname "$artifact")"
      while [[ "$dir" != "/" && "$dir" != "." ]]; do
        local base
        base="$(basename "$dir")"
        if [[ "$base" == lib* || "$base" == bin* ]]; then
          dirname "$dir"
          return 0
        fi
        dir="$(dirname "$dir")"
      done
      # Fallback: keep the conventional root.
      echo "$ICU_SRC_UNIX"
    }

    ICU_LIB_FILE_UNIX="$(find_icu_lib)"
    ICU_ROOT_UNIX="$ICU_SRC_UNIX"
    if [[ -n "$ICU_LIB_FILE_UNIX" ]]; then
      ICU_ROOT_UNIX="$(icu_root_from_artifact "$ICU_LIB_FILE_UNIX")"
    fi

    if [[ -z "$ICU_LIB_FILE_UNIX" ]]; then
      echo "Building ICU $ICU_VER from source (this can take a while)"
      rm -rf "$ICU_WORK_UNIX"
      mkdir -p "$ICU_WORK_UNIX"
      curl -L --retry 10 --retry-connrefused --silent --show-error --fail \
        "https://github.com/unicode-org/icu/releases/download/release-$ICU_TAG/icu4c-$ICU_VER-src.zip" \
        -o "$ICU_WORK_UNIX/icu4c-$ICU_VER-src.zip"

      if command -v 7z >/dev/null 2>&1; then
        7z x "$ICU_WORK_UNIX/icu4c-$ICU_VER-src.zip" "-o$ICU_WORK_UNIX" >/dev/null
      else
        powershell.exe -NoProfile -Command "Expand-Archive -Force '$ICU_WORK_UNIX\\icu4c-$ICU_VER-src.zip' '$ICU_WORK_UNIX'"
      fi

      if command -v cygpath >/dev/null 2>&1; then
        ALLINONE_WIN="$(cygpath -w "$ICU_SRC_UNIX/allinone")"
      else
        ALLINONE_WIN="$ICU_SRC_UNIX/allinone"
      fi

      # Build Release x64 via MSBuild (Visual Studio is available on GitHub Actions runners).
      echo "Building ICU via MSBuild in: $ICU_SRC_UNIX/allinone"
      # ICU 61.x projects may target the legacy Windows 8.1 SDK by default, which is not installed
      # on modern GitHub Actions runners. Prefer the latest installed Windows 10 SDK instead.
      WINSDK_VER=""
      WINSDK_LIB_ROOT="/c/Program Files (x86)/Windows Kits/10/Lib"
      if [[ -d "$WINSDK_LIB_ROOT" ]]; then
        WINSDK_VER="$(ls -1 "$WINSDK_LIB_ROOT" 2>/dev/null | sort -V | tail -n 1 || true)"
      fi
      if [[ -n "$WINSDK_VER" ]]; then
        echo "Using Windows SDK: $WINSDK_VER"
      fi
      ICU_TOOLSET="v143"
      echo "Using MSVC toolset: $ICU_TOOLSET"
      ICU_MSBUILD_ARGS=(
        allinone.sln
        /m
        /p:Configuration=Release
        /p:Platform=x64
      )
      if [[ -n "$WINSDK_VER" ]]; then
        ICU_MSBUILD_ARGS+=("/p:WindowsTargetPlatformVersion=$WINSDK_VER")
      fi
      ICU_MSBUILD_ARGS+=("/p:PlatformToolset=$ICU_TOOLSET")
      ICU_MSBUILD_EXE=""
      if command -v msbuild >/dev/null 2>&1; then
        ICU_MSBUILD_EXE="msbuild"
      else
        echo "msbuild not found on PATH; resolving via vswhere"
        if command -v powershell.exe >/dev/null 2>&1; then
          MSBUILD_WIN="$(powershell.exe -NoProfile -Command '$ErrorActionPreference="Stop"; & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "MSBuild\**\Bin\MSBuild.exe"' | tr -d '\r' | head -n 1)"
        else
          MSBUILD_WIN=""
        fi
        if [[ -z "$MSBUILD_WIN" ]]; then
          echo "Could not locate MSBuild.exe via vswhere; install Visual Studio Build Tools 2022" >&2
          exit 1
        fi

        if command -v cygpath >/dev/null 2>&1; then
          MSBUILD_EXE_UNIX="$(cygpath -u "$MSBUILD_WIN")"
        else
          MSBUILD_EXE_UNIX="$MSBUILD_WIN"
        fi

        echo "Using MSBuild: $MSBUILD_WIN"
        ICU_MSBUILD_EXE="$MSBUILD_EXE_UNIX"
      fi

      # ICU's allinone solution can fail intermittently on GitHub-hosted Windows
      # runners (custom build tools racing under heavy parallel load). Retry a
      # couple of times before failing the job.
      for attempt in 1 2 3; do
        echo "ICU MSBuild attempt $attempt/3"
        # NOTE: In Git Bash (MSYS), arguments that start with `/` can be treated as paths.
        # Disable argument path conversion so MSBuild receives `/p:...` flags unchanged.
        if (cd "$ICU_SRC_UNIX/allinone" && MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$ICU_MSBUILD_EXE" "${ICU_MSBUILD_ARGS[@]}"); then
          break
        fi
        if [[ "$attempt" == "3" ]]; then
          echo "ICU MSBuild failed after 3 attempts" >&2
          exit 1
        fi
        echo "ICU MSBuild failed; retrying in 10 seconds" >&2
        sleep 10
      done

      ICU_LIB_FILE_UNIX="$(find_icu_lib)"
      if [[ -z "$ICU_LIB_FILE_UNIX" ]]; then
        echo "ICU build did not produce icu*.lib under: $ICU_WORK_UNIX" >&2
        echo "ICU work tree (top-level):" >&2
        find "$ICU_WORK_UNIX" -maxdepth 3 -type d -print | head -n 200 >&2 || true
        exit 1
      fi
      ICU_ROOT_UNIX="$(icu_root_from_artifact "$ICU_LIB_FILE_UNIX")"
    fi

    echo "ICU import lib: $ICU_LIB_FILE_UNIX"
    echo "ICU root: $ICU_ROOT_UNIX"
    ICU_ROOT_NORM="$ICU_ROOT_UNIX"
    if command -v cygpath >/dev/null 2>&1; then
      ICU_ROOT_NORM="$(cygpath -m "$ICU_ROOT_UNIX")"
    fi

    # Persist ICU to subsequent CI steps if running inside GitHub Actions.
    if [[ -n "${GITHUB_ENV:-}" ]]; then
      echo "MLN_ICU_ROOT=$ICU_ROOT_NORM" >> "$GITHUB_ENV"
    fi
    if [[ -n "${GITHUB_PATH:-}" ]]; then
      # If ICU is built as DLLs, ensure they're discoverable at runtime.
      if [[ -d "$ICU_ROOT_UNIX/bin64" ]]; then
        # MapLibre Native's precompiled Windows core may load unversioned ICU DLL names
        # (e.g. `icuuc.dll`) even when the ICU build outputs version-suffixed DLLs
        # (e.g. `icuuc61.dll`). Provide unversioned aliases to avoid accidentally
        # picking up unrelated ICU DLLs already present on the runner PATH.
        for base in icuuc icuin icudt; do
          if [[ ! -f "$ICU_ROOT_UNIX/bin64/${base}.dll" ]]; then
            src="$(find "$ICU_ROOT_UNIX/bin64" -maxdepth 1 -type f -iname "${base}[0-9]*.dll" -print | sort -V | head -n 1 || true)"
            if [[ -n "$src" ]]; then
              cp -f "$src" "$ICU_ROOT_UNIX/bin64/${base}.dll"
            fi
          fi
        done
        echo "$ICU_ROOT_NORM/bin64" >> "$GITHUB_PATH"
      fi
      if [[ -d "$ICU_ROOT_UNIX/bin" ]]; then
        echo "$ICU_ROOT_NORM/bin" >> "$GITHUB_PATH"
      fi
    fi

# Show current maplibre-native dependency information
maplibre-native-info: (assert-cmd "curl") (assert-cmd "jq")
    #!/usr/bin/env bash
    set -euo pipefail

    MLN_REPO="$(just get-crate-field 'metadata.mln.repo')"
    MLN_CORE_RELEASE_SHA="$(just get-crate-field 'metadata.mln.release')"

    echo "Github Repo: ${MLN_REPO}"
    echo "Release: ${MLN_CORE_RELEASE_SHA}"

    COMMIT_INFO=$(curl -s "https://api.github.com/repos/$MLN_REPO/commits/$MLN_CORE_RELEASE_SHA" 2>/dev/null)
    if [[ "$COMMIT_INFO" != "null" ]]; then
        echo "Message: $(echo "$COMMIT_INFO" | jq -r '.commit.message' | head -n1)"
        echo "Date: $(echo "$COMMIT_INFO" | jq -r '.commit.author.date')"
    fi

# Find the minimum supported Rust version (MSRV) using cargo-msrv extension, and update Cargo.toml
msrv:  (cargo-install 'cargo-msrv')
    cargo msrv find --write-msrv --ignore-lockfile

package:
    cargo package

# Run cargo-release
release *args='':  (cargo-install 'release-plz')
    release-plz {{args}}

# Run the demo binary
run *ARGS:
    cargo run -p render -- {{ARGS}}

# Check semver compatibility with prior published version. Install it with `cargo install cargo-semver-checks`
semver *args:  (cargo-install 'cargo-semver-checks')
    cargo semver-checks {{args}}

# Run testcases against a specific backend
test backend='vulkan':
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "${OS:-}" == "Windows_NT" ]]; then
      shopt -s nullglob

      # Ensure the correct DLLs are discovered first at runtime.
      #
      # On GitHub Actions, the runner PATH can contain other copies of ANGLE/ICU
      # (for example via MSYS), and Windows will load DLLs from the first match.
      # Prepending the vcpkg + ICU bin directories avoids picking up incompatible DLLs.
      if [[ -n "${VCPKG_ROOT:-}" ]] && command -v cygpath >/dev/null 2>&1; then
        VCPKG_ROOT_UNIX="$(cygpath -u "$VCPKG_ROOT")"
        if [[ -d "$VCPKG_ROOT_UNIX/installed/x64-windows/bin" ]]; then
          export PATH="$VCPKG_ROOT_UNIX/installed/x64-windows/bin:$PATH"
        fi
      fi
      if [[ -n "${MLN_ICU_ROOT:-}" ]] && command -v cygpath >/dev/null 2>&1; then
        ICU_ROOT_UNIX="$(cygpath -u "$MLN_ICU_ROOT")"
        if [[ -d "$ICU_ROOT_UNIX/bin64" ]]; then
          export PATH="$ICU_ROOT_UNIX/bin64:$PATH"
        elif [[ -d "$ICU_ROOT_UNIX/bin" ]]; then
          export PATH="$ICU_ROOT_UNIX/bin:$PATH"
        fi
      fi

      # EGL_PLATFORM is used on Linux (Mesa) to select surfaceless headless rendering.
      # When set on Windows, ANGLE can take an unexpected code path during DLL init.
      unset EGL_PLATFORM || true
      # Force ANGLE to use a software renderer on CI runners to avoid driver issues.
      export ANGLE_DEFAULT_PLATFORM="${ANGLE_DEFAULT_PLATFORM:-warp}"
      if [[ "{{backend}}" == "vulkan" ]]; then
        if [[ -n "${VK_ICD_FILENAMES:-}" ]]; then
          export VK_DRIVER_FILES="${VK_DRIVER_FILES:-$VK_ICD_FILENAMES}"
        fi
        # The precompiled Windows Vulkan core expects explicit layers such as
        # `VK_LAYER_LUNARG_monitor`. When Vulkan SDK is installed in CI, point the loader
        # to the SDK layer manifests explicitly to avoid depending on machine-global setup.
        if [[ -n "${VULKAN_SDK:-}" ]]; then
          VULKAN_SDK_UNIX="$VULKAN_SDK"
          VULKAN_SDK_SED="$VULKAN_SDK"
          VULKAN_SDK_ENV="$VULKAN_SDK"
          LAYER_ALIAS_DIR_UNIX="$(pwd)/target/vulkan-layer-manifests"
          LAYER_ALIAS_DIR_ENV="$LAYER_ALIAS_DIR_UNIX"
          VK_LAYER_ALIAS_MANIFEST=""
          if command -v cygpath >/dev/null 2>&1; then
            VULKAN_SDK_UNIX="$(cygpath -u "$VULKAN_SDK")"
            # Use slash-separated form for JSON replacement content.
            VULKAN_SDK_SED="$(cygpath -m "$VULKAN_SDK")"
            # Use native Windows form for loader environment variables.
            VULKAN_SDK_ENV="$(cygpath -w "$VULKAN_SDK")"
            LAYER_ALIAS_DIR_ENV="$(cygpath -w "$LAYER_ALIAS_DIR_UNIX")"
          fi
          if [[ -d "$VULKAN_SDK_UNIX/Bin" ]]; then
            # Prefer the SDK Vulkan loader over any other vulkan-1.dll on PATH.
            export PATH="$VULKAN_SDK_UNIX/Bin:$PATH"
            mkdir -p "$LAYER_ALIAS_DIR_UNIX"
            if [[ -f "$VULKAN_SDK_UNIX/Bin/VkLayer_monitor.json" ]]; then
              # Some SDK revisions ship the monitor layer under a different logical name.
              # Create an alias manifest with the exact name expected by precompiled core.
              ALIAS_MANIFEST_UNIX="$LAYER_ALIAS_DIR_UNIX/VkLayer_lunarg_monitor_alias.json"
              cp -f "$VULKAN_SDK_UNIX/Bin/VkLayer_monitor.json" "$ALIAS_MANIFEST_UNIX"
              sed -E \
                '0,/"name"[[:space:]]*:[[:space:]]*"[^"]+"/s//"name": "VK_LAYER_LUNARG_monitor"/' \
                "$ALIAS_MANIFEST_UNIX" > "$ALIAS_MANIFEST_UNIX.tmp"
              mv -f "$ALIAS_MANIFEST_UNIX.tmp" "$ALIAS_MANIFEST_UNIX"
              sed -E \
                "0,/\"library_path\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/s#\"library_path\"[[:space:]]*:[[:space:]]*\"[^\"]+\"#\"library_path\": \"$VULKAN_SDK_SED/Bin/VkLayer_monitor.dll\"#" \
                "$ALIAS_MANIFEST_UNIX" > "$ALIAS_MANIFEST_UNIX.tmp"
              mv -f "$ALIAS_MANIFEST_UNIX.tmp" "$ALIAS_MANIFEST_UNIX"
              VK_LAYER_ALIAS_MANIFEST="$LAYER_ALIAS_DIR_ENV\\VkLayer_lunarg_monitor_alias.json"
              export VK_LAYER_PATH="${VK_LAYER_PATH:-$LAYER_ALIAS_DIR_ENV;$VULKAN_SDK_ENV\\Bin}"
              # Keep defaults while appending our explicit layer directory.
              export VK_ADD_LAYER_PATH="${VK_ADD_LAYER_PATH:-$VK_LAYER_PATH}"
              echo "Found Vulkan monitor layer manifest: $VULKAN_SDK_SED/Bin/VkLayer_monitor.json"
              echo "Created Vulkan monitor layer alias manifest: $LAYER_ALIAS_DIR_ENV\\VkLayer_lunarg_monitor_alias.json"
            else
              # VK_LAYER_PATH is consumed by the Windows Vulkan loader, so keep it as a
              # Windows-style path (e.g. D:/.../VULKAN_SDK/Bin), not MSYS (/d/...).
              export VK_LAYER_PATH="${VK_LAYER_PATH:-$VULKAN_SDK_ENV\\Bin}"
              export VK_ADD_LAYER_PATH="${VK_ADD_LAYER_PATH:-$VK_LAYER_PATH}"
              echo "Vulkan monitor layer manifest not found under: $VULKAN_SDK_SED/Bin" >&2
            fi
            export VK_LOADER_DEBUG="${VK_LOADER_DEBUG:-error,warn,layer}"
            echo "VK_LAYER_PATH=$VK_LAYER_PATH"
            echo "VK_ADD_LAYER_PATH=${VK_ADD_LAYER_PATH:-<unset>}"
            echo "VK_DRIVER_FILES=${VK_DRIVER_FILES:-<unset>}"
            echo "VK_LOADER_DEBUG=$VK_LOADER_DEBUG"
          fi
        fi

        # Git Bash (MSYS2) can rewrite path-like environment variables when invoking
        # native Windows executables. Vulkan loader variables must stay Windows-native.
        VULKAN_ENV_CONV_EXCL='VK_ICD_FILENAMES;VK_DRIVER_FILES;VK_LAYER_PATH;VK_ADD_LAYER_PATH;VULKAN_SDK'
        if [[ -n "${MSYS2_ENV_CONV_EXCL:-}" ]]; then
          export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL};${VULKAN_ENV_CONV_EXCL}"
        else
          export MSYS2_ENV_CONV_EXCL="$VULKAN_ENV_CONV_EXCL"
        fi
        echo "MSYS2_ENV_CONV_EXCL=$MSYS2_ENV_CONV_EXCL"

        if command -v cmd.exe >/dev/null 2>&1; then
          echo "cmd sees VK_ICD_FILENAMES: $(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 cmd.exe /d /c "echo %VK_ICD_FILENAMES%" | tr -d '\r')"
          echo "cmd sees VK_DRIVER_FILES: $(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 cmd.exe /d /c "echo %VK_DRIVER_FILES%" | tr -d '\r')"
          echo "cmd sees VK_LAYER_PATH: $(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 cmd.exe /d /c "echo %VK_LAYER_PATH%" | tr -d '\r')"
        fi

        # Some Windows loaders on CI still rely on registry discovery even when
        # environment overrides are set. Register our manifests explicitly.
        register_vulkan_registry_manifest() {
          local root="$1"
          local kind="$2"
          local manifest="$3"
          local key=""
          if [[ -z "$manifest" ]]; then
            return 0
          fi
          if [[ "$kind" == "driver" ]]; then
            key="$root\\SOFTWARE\\Khronos\\Vulkan\\Drivers"
          else
            key="$root\\SOFTWARE\\Khronos\\Vulkan\\ExplicitLayers"
          fi
          if MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 reg.exe add "$key" /v "$manifest" /t REG_DWORD /d 0 /f >/dev/null 2>&1; then
            echo "Registered Vulkan $kind manifest in $key: $manifest"
          else
            echo "Warning: failed to register Vulkan $kind manifest in $key: $manifest" >&2
          fi
        }

        VK_ICD_REG_VALUE="${VK_ICD_FILENAMES%%;*}"
        for root in HKLM HKCU; do
          register_vulkan_registry_manifest "$root" driver "$VK_ICD_REG_VALUE"
          register_vulkan_registry_manifest "$root" layer "${VK_LAYER_ALIAS_MANIFEST:-}"
        done

        for root in HKLM HKCU; do
          echo "Vulkan registry drivers ($root):"
          MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 reg.exe query "$root\\SOFTWARE\\Khronos\\Vulkan\\Drivers" || true
          echo "Vulkan registry explicit layers ($root):"
          MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 reg.exe query "$root\\SOFTWARE\\Khronos\\Vulkan\\ExplicitLayers" || true
        done
      fi

      # Windows searches System32 before PATH for some DLLs. To avoid accidentally
      # loading unrelated ICU DLLs already present on the runner, place the required
      # runtime DLLs next to the test executables (application directory is searched first).
      cargo test --all-targets --features {{backend}} --workspace --no-run
      DEPS_DIR="target/debug/deps"
      mkdir -p "$DEPS_DIR"

      if [[ -n "${VCPKG_ROOT_UNIX:-}" && -d "$VCPKG_ROOT_UNIX/installed/x64-windows/bin" ]]; then
        for dll in "$VCPKG_ROOT_UNIX/installed/x64-windows/bin"/*.dll; do
          dll_name="$(basename "$dll")"
          if [[ "{{backend}}" == "vulkan" && "${dll_name,,}" == "vulkan-1.dll" ]]; then
            # For Vulkan tests, use the SDK loader. vcpkg's loader can diverge in
            # behavior (layer/ICD discovery), causing CI-only runtime failures.
            continue
          fi
          cp -f "$dll" "$DEPS_DIR/"
        done
      fi

      if [[ -n "${ICU_ROOT_UNIX:-}" && -d "$ICU_ROOT_UNIX/bin64" ]]; then
        for dll in "$ICU_ROOT_UNIX/bin64"/icu*.dll; do
          cp -f "$dll" "$DEPS_DIR/"
        done
        # Provide unversioned aliases if the import table references `icu*.dll`.
        for base in icuuc icuin icudt; do
          if [[ ! -f "$DEPS_DIR/${base}.dll" ]]; then
            src="$(ls -1 "$DEPS_DIR/${base}"[0-9]*.dll 2>/dev/null | sort -V | head -n 1 || true)"
            if [[ -n "$src" ]]; then
              cp -f "$src" "$DEPS_DIR/${base}.dll"
            fi
          fi
        done
      fi

      if [[ "{{backend}}" == "vulkan" && -n "${VCPKG_ROOT_UNIX:-}" ]]; then
        VCPKG_BIN_UNIX="$VCPKG_ROOT_UNIX/installed/x64-windows/bin"
        if [[ -d "$VCPKG_BIN_UNIX" ]]; then
          # Avoid loading vcpkg's vulkan-1.dll at runtime; use the system loader instead.
          PATH=":$PATH:"
          PATH="${PATH//:$VCPKG_BIN_UNIX:/:}"
          PATH="${PATH#:}"
          PATH="${PATH%:}"
          export PATH
          echo "Removed vcpkg runtime bin from PATH for Vulkan tests: $VCPKG_BIN_UNIX"
        fi
      fi

      # Helpful diagnostics in CI logs (doesn't affect behavior).
      if command -v where.exe >/dev/null 2>&1; then
        echo "where libEGL.dll:" && where.exe libEGL.dll || true
        echo "where libGLESv2.dll:" && where.exe libGLESv2.dll || true
        # Quote the wildcard so bash doesn't expand it (especially with `nullglob`).
        echo "where icuuc*.dll:" && where.exe 'icuuc*.dll' || true
        if [[ "{{backend}}" == "vulkan" ]]; then
          echo "where vulkan-1.dll:" && where.exe vulkan-1.dll || true
          echo "where VkLayer_monitor.dll:" && where.exe VkLayer_monitor.dll || true
          echo "where VkLayer_khronos_validation.dll:" && where.exe VkLayer_khronos_validation.dll || true
        fi
      fi
    fi

    if [[ "${OS:-}" == "Windows_NT" ]]; then
      cleanup_ci_vulkan_sdk_artifacts() {
        if [[ "{{backend}}" != "vulkan" ]]; then
          return 0
        fi
        local repo_root
        repo_root="$(pwd)"
        local ci_sdk_dir="$repo_root/VULKAN_SDK"
        local ci_sdk_installer="$repo_root/vulkan_sdk.exe"

        # Keep local developer SDKs intact. Only clean CI-local artefacts created
        # under the repository root by the install-vulkan-sdk action.
        if [[ -n "${VULKAN_SDK:-}" ]]; then
          local sdk_unix="$VULKAN_SDK"
          if command -v cygpath >/dev/null 2>&1; then
            sdk_unix="$(cygpath -u "$VULKAN_SDK")"
          fi
          if [[ "$sdk_unix" == "$ci_sdk_dir" && -d "$ci_sdk_dir" ]]; then
            rm -rf "$ci_sdk_dir"
            echo "Removed CI-local Vulkan SDK directory: $ci_sdk_dir"
          fi
        fi
        if [[ -f "$ci_sdk_installer" ]]; then
          rm -f "$ci_sdk_installer"
          echo "Removed CI-local Vulkan installer: $ci_sdk_installer"
        fi
      }

      set +e
      cargo_log="$(mktemp)"
      # Capture test output so we can identify the crashing test executable.
      cargo test --all-targets --features {{backend}} --workspace 2>&1 | tee "$cargo_log"
      status="${PIPESTATUS[0]:-1}"
      set -e

      if [[ "$status" != "0" ]]; then
        echo "cargo test failed (exit=$status); attempting to capture a native backtrace"

        failed_exe="$(
          tr -d '\r' < "$cargo_log" \
            | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' \
            | sed -nE 's/.*process didn.?t exit successfully: `([^`]*\.exe)`.*/\1/p' \
            | tail -n 1 || true
        )"
        if [[ -n "$failed_exe" ]]; then
          echo "failing test exe: $failed_exe"
        fi

        test_exe="$failed_exe"
        if [[ -z "$test_exe" ]]; then
          test_exe="$(ls -1 target/debug/deps/maplibre_native-*.exe 2>/dev/null | head -n 1 || true)"
        fi
        if [[ -n "$test_exe" ]]; then
          echo "debug target exe: $test_exe"
        else
          echo "Could not locate maplibre_native test exe under target/debug/deps" >&2
        fi

        CDB=""
        if command -v cdb.exe >/dev/null 2>&1; then
          CDB="cdb.exe"
        else
          for candidate in \
            "/c/Program Files (x86)/Windows Kits/10/Debuggers/x64/cdb.exe" \
            "/c/Program Files (x86)/Windows Kits/10/Debuggers/x86/cdb.exe" \
            ; do
            if [[ -f "$candidate" ]]; then
              CDB="$candidate"
              break
            fi
          done
        fi

        if [[ -n "$CDB" && -n "$test_exe" ]]; then
          echo "Using debugger: $CDB"
          # Run until the first fatal event, then print the exception and a stack trace.
          "$CDB" -c ".symfix; .reload; sxe av; g; .lastevent; !analyze -v; lm; .ecxr; ~* kb; q" "$test_exe" || true
        else
          echo "cdb.exe not found (or test exe missing); skipping native backtrace capture" >&2
        fi
      fi

      cleanup_ci_vulkan_sdk_artifacts
      exit "$status"
    fi

    cargo test --all-targets --features {{backend}} --workspace

# Run all tests and accept the changes. Requires cargo-insta to be installed.
test-accept:
    cargo insta test --accept

# Run all tests
test-all:
    cargo test --all-targets --workspace

# Test documentation generation
test-doc backend: (docs backend '')

# Test code formatting
test-fmt: (fmt-toml '--check' '--check-format')
    cargo fmt --all -- --check

# Run testcases against a specific backend
test-miri backend='vulkan':
    MIRIFLAGS="" cargo miri test --all-targets --features {{backend}} --workspace

test-publishing:
    cargo publish --dry-run

# Find unused dependencies. Install it with `cargo install cargo-udeps`
udeps:  (cargo-install 'cargo-udeps')
    cargo +nightly udeps --workspace --all-targets

# Update all dependencies, including breaking changes. Requires nightly toolchain (install with `rustup install nightly`)
update:
    cargo +nightly -Z unstable-options update --breaking
    cargo update

# Update maplibre-native dependency to latest core release
update-maplibre-native: (assert-cmd "curl") (assert-cmd "jq")
    #!/usr/bin/env bash
    set -euo pipefail

    MLN_REPO="$(just get-crate-field 'metadata.mln.repo')"
    MLN_CORE_RELEASE_SHA="$(just get-crate-field 'metadata.mln.release')"

    # Hit the GitHub releases API for maplibre-native and pull the latest
    # releases, avoiding drafts and prereleases.
    RELEASES_URL="https://api.github.com/repos/$MLN_REPO/releases?per_page=200"

    MLN_RELEASES=$(mktemp)
    trap 'rm -f "$MLN_RELEASES"' EXIT

    curl -s "$RELEASES_URL" | jq 'map(select((.draft | not) and (.prerelease | not))) | sort_by(.published_at) | reverse' > "$MLN_RELEASES"

    if [[ $(jq 'length' "$MLN_RELEASES") -eq 0 ]]; then
        echo "ERROR: No releases found for GitHub repo $MLN_REPO"
        exit 1
    fi

    LATEST_MLN_CORE_RELEASE_SHA=$(jq -r --arg prefix "core-" 'map(select(.tag_name | startswith($prefix))) | .[0].tag_name' "$MLN_RELEASES")

    if [[ -z "$LATEST_MLN_CORE_RELEASE_SHA" || "$LATEST_MLN_CORE_RELEASE_SHA" == "null" ]]; then
        echo "ERROR: no Maplibre Native Core release found"
        echo "Release tags found:"
        jq -r '.[].tag_name' "$MLN_RELEASES"
        exit 1
    fi

    if [[ "$MLN_CORE_RELEASE_SHA" == "$LATEST_MLN_CORE_RELEASE_SHA" ]]; then
        echo "Already up to date: $LATEST_MLN_CORE_RELEASE_SHA"
    else
        echo "Updating Maplibre Native Core from $MLN_CORE_RELEASE_SHA to $LATEST_MLN_CORE_RELEASE_SHA"
        sed -i.tmp -E "/\[package\.metadata\.mln\]/,/^\[/{s/release\s*=\s*\"[^\"]+\"/release = \"$LATEST_MLN_CORE_RELEASE_SHA\"/}" Cargo.toml && \
        rm -f Cargo.toml.tmp
    fi

# Ensure that a certain command is available
[private]
assert-cmd command:
    @if ! type {{command}} > /dev/null; then \
        echo "Command '{{command}}' could not be found. Please make sure it has been installed on your computer." ;\
        exit 1 ;\
    fi

# Make sure the git repo has no uncommitted changes
[private]
assert-git-is-clean:
    @if [ -n "$(git status --untracked-files --porcelain)" ]; then \
      >&2 echo "ERROR: git repo is no longer clean. Make sure compilation and tests artifacts are in the .gitignore, and no repo files are modified." ;\
      >&2 echo "######### git status ##########" ;\
      git status ;\
      git --no-pager diff ;\
      exit 1 ;\
    fi

# Check if a certain Cargo command is installed, and install it if needed
[private]
cargo-install $COMMAND $INSTALL_CMD='' *args='':
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v $COMMAND > /dev/null; then
        if ! command -v cargo-binstall > /dev/null; then
            echo "$COMMAND could not be found. Installing it with    cargo install ${INSTALL_CMD:-$COMMAND} --locked {{args}}"
            cargo install ${INSTALL_CMD:-$COMMAND} --locked {{args}}
        else
            echo "$COMMAND could not be found. Installing it with    cargo binstall ${INSTALL_CMD:-$COMMAND} --locked {{args}}"
            cargo binstall ${INSTALL_CMD:-$COMMAND} --locked {{args}}
        fi
    fi
