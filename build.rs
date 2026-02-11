//! File for defining how we download and link against `MapLibre Native`.

use std::path::{Path, PathBuf};
use std::{env, fs};

use downloader::{Download, Downloader};
use walkdir::WalkDir;

/// Read `package.metadata.mln.release` from `Cargo.toml`.
///
/// We intentionally parse with a tiny, dependency-free routine to avoid adding
/// build dependencies.
fn read_mln_revision(crate_root: &Path) -> String {
    let cargo_toml = crate_root.join("Cargo.toml");
    let content = fs::read_to_string(&cargo_toml)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", cargo_toml.display()));

    let mut in_section = false;
    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            in_section = line == "[package.metadata.mln]";
            continue;
        }
        if !in_section {
            continue;
        }
        // Accept common formatting: release = "core-..."
        if let Some(rest) = line.strip_prefix("release") {
            let rest = rest.trim_start();
            if let Some(rest) = rest.strip_prefix('=') {
                let v = rest.trim();
                let v = v
                    .strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(v);
                assert!(
                    v.starts_with("core-"),
                    "Expected package.metadata.mln.release to start with 'core-', got '{v}'"
                );
                return v.to_string();
            }
        }
    }
    panic!(
        "Could not find [package.metadata.mln] release in {}",
        cargo_toml.display()
    );
}

fn core_release_from_env(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(raw) => {
            let v = raw.trim();
            if v.is_empty() {
                return None;
            }
            assert!(
                v.starts_with("core-"),
                "Expected {key} to start with 'core-', got '{v}'"
            );
            Some(v.to_string())
        }
        Err(env::VarError::NotPresent) => None,
        Err(env::VarError::NotUnicode(_)) => {
            panic!("{key} must be valid Unicode if set (got non-Unicode value)")
        }
    }
}

fn select_mln_revision(crate_root: &Path, target_os: &str) -> String {
    println!("cargo:rerun-if-env-changed=MLN_CORE_RELEASE");
    println!("cargo:rerun-if-env-changed=MLN_CORE_RELEASE_WINDOWS");
    println!("cargo:rerun-if-env-changed=MLN_CORE_RELEASE_MACOS");
    println!("cargo:rerun-if-env-changed=MLN_CORE_RELEASE_LINUX");

    if let Some(v) = core_release_from_env("MLN_CORE_RELEASE") {
        println!("cargo:warning=Using MLN core release override from MLN_CORE_RELEASE={v}");
        return v;
    }

    let os_key = match target_os {
        "windows" => "MLN_CORE_RELEASE_WINDOWS",
        "macos" => "MLN_CORE_RELEASE_MACOS",
        "linux" => "MLN_CORE_RELEASE_LINUX",
        _ => "",
    };
    if !os_key.is_empty() {
        if let Some(v) = core_release_from_env(os_key) {
            println!("cargo:warning=Using MLN core release override from {os_key}={v}");
            return v;
        }
    }

    read_mln_revision(crate_root)
}

#[derive(Debug, Clone)]
struct CoreDownload {
    library_file: PathBuf,
    headers_file: PathBuf,
    link_name: String,
}

fn default_mln_cache_dir(crate_root: &Path) -> PathBuf {
    println!("cargo:rerun-if-env-changed=MLN_CORE_CACHE_DIR");
    println!("cargo:rerun-if-env-changed=CARGO_TARGET_DIR");

    if let Some(dir) = env::var_os("MLN_CORE_CACHE_DIR") {
        return PathBuf::from(dir);
    }
    if let Some(dir) = env::var_os("CARGO_TARGET_DIR") {
        return PathBuf::from(dir).join("mln-core-cache");
    }
    crate_root.join("target").join("mln-core-cache")
}

/// Supported graphics rendering APIs.
#[derive(PartialEq, Eq, Clone, Copy)]
enum GraphicsRenderingAPI {
    /// [Apple's Metal API](https://developer.apple.com/metal/) (macOS/iOS only)
    Metal,
    /// [OpenGL API](https://www.opengl.org/)
    OpenGL,
    /// [Vulkan API](https://www.vulkan.org/)
    Vulkan,
}
impl GraphicsRenderingAPI {
    /// Selects the rendering API based on enabled cargo features and platform.
    ///
    /// - If one feature is enabled, it is used.
    /// - If none are enabled, defaults to Metal on macOS/iOS, Vulkan elsewhere.
    /// - If multiple are enabled, falls back to OpenGL > Metal > Vulkan, with a warning.
    fn from_selected_features() -> Self {
        let with_opengl = env::var("CARGO_FEATURE_OPENGL").is_ok();
        let with_metal = env::var("CARGO_FEATURE_METAL").is_ok();
        let with_vulkan = env::var("CARGO_FEATURE_VULKAN").is_ok();

        let target_os = env::var("CARGO_CFG_TARGET_OS").expect("CARGO_CFG_TARGET_OS not set");
        let is_macos = target_os == "ios" || target_os == "macos";

        match (with_metal, with_vulkan, with_opengl) {
            (true, false, false) => Self::Metal,
            (false, true, false) => Self::Vulkan,
            (false, false, true) => Self::OpenGL,
            (false, false, false) => {
                if is_macos {
                    Self::Metal
                } else {
                    Self::Vulkan
                }
            }
            (_, _, _) => {
                // TODO: modify for better defaults
                // This might not be the best logic, but it can change at any moment because it's a fallback with a warning
                // Current logic: if opengl is enabled, always use that, otherwise pick metal on macOS and vulkan on other platforms
                println!("cargo::warning=Features 'metal', 'opengl', and 'vulkan' are mutually exclusive.");

                let default_choice = if with_opengl {
                    Self::OpenGL
                } else if is_macos {
                    Self::Metal
                } else {
                    Self::Vulkan
                };
                println!("cargo::warning=Using only '{default_choice}', but this default selection may change in future releases.");
                default_choice
            }
        }
    }
}
impl std::fmt::Display for GraphicsRenderingAPI {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Metal => f.write_str("metal"),
            Self::OpenGL => f.write_str("opengl"),
            Self::Vulkan => f.write_str("vulkan"),
        }
    }
}

fn derive_link_name(path: &Path) -> String {
    let file = path
        .file_name()
        .unwrap_or_else(|| panic!("MLN library path has no file name: {}", path.display()))
        .to_string_lossy();

    if let Some(stem) = file.strip_prefix("lib").and_then(|s| s.strip_suffix(".a")) {
        return stem.to_string();
    }
    if let Some(stem) = file.strip_suffix(".a") {
        return stem.to_string();
    }
    if let Some(stem) = file.strip_suffix(".lib") {
        return stem.to_string();
    }
    panic!("Unsupported MLN library filename: {file}");
}

fn select_asset_name(api: GraphicsRenderingAPI) -> (String, String) {
    let target_os = env::var("CARGO_CFG_TARGET_OS").expect("CARGO_CFG_TARGET_OS not set");
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").expect("CARGO_CFG_TARGET_ARCH not set");

    match (target_os.as_str(), target_arch.as_str(), api) {
        // Linux: prefer amalgamated libs for smaller downloads.
        ("linux", "aarch64", GraphicsRenderingAPI::Vulkan) => (
            "libmaplibre-native-core-amalgam-linux-arm64-vulkan.a".to_string(),
            "maplibre-native-core-amalgam-linux-arm64-vulkan".to_string(),
        ),
        ("linux", "aarch64", GraphicsRenderingAPI::OpenGL) => (
            "libmaplibre-native-core-amalgam-linux-arm64-opengl.a".to_string(),
            "maplibre-native-core-amalgam-linux-arm64-opengl".to_string(),
        ),
        ("linux", "x86_64", GraphicsRenderingAPI::Vulkan) => (
            "libmaplibre-native-core-amalgam-linux-x64-vulkan.a".to_string(),
            "maplibre-native-core-amalgam-linux-x64-vulkan".to_string(),
        ),
        ("linux", "x86_64", GraphicsRenderingAPI::OpenGL) => (
            "libmaplibre-native-core-amalgam-linux-x64-opengl.a".to_string(),
            "maplibre-native-core-amalgam-linux-x64-opengl".to_string(),
        ),

        // macOS: use the non-amalgamated static library.
        //
        // The amalgamated macOS static library published by maplibre-native currently contains
        // many required mbgl symbols as "non-external", which makes them impossible to link
        // against from our separately-compiled C++ bridge object files.
        ("macos", "aarch64", GraphicsRenderingAPI::Metal) => (
            "libmaplibre-native-core-macos-arm64-metal.a".to_string(),
            "maplibre-native-core-macos-arm64-metal".to_string(),
        ),

        // Windows: released as .lib without the "lib" prefix.
        ("windows", "x86_64", GraphicsRenderingAPI::Vulkan) => (
            "maplibre-native-core-windows-x64-vulkan.lib".to_string(),
            "maplibre-native-core-windows-x64-vulkan".to_string(),
        ),
        ("windows", "x86_64", GraphicsRenderingAPI::OpenGL) => (
            // Use the EGL build for headless rendering on CI (ANGLE).
            //
            // The plain OpenGL build relies on WGL and has been observed to crash in
            // headless GitHub Actions environments during rendering tests.
            "maplibre-native-core-windows-x64-egl.lib".to_string(),
            "maplibre-native-core-windows-x64-egl".to_string(),
        ),

        // Not currently supported by the published core artefacts.
        ("macos", _, GraphicsRenderingAPI::Vulkan | GraphicsRenderingAPI::OpenGL) => {
            panic!("Unsupported backend '{api}' for macOS: only 'metal' is currently available via core artefacts");
        }
        ("windows", _, GraphicsRenderingAPI::Metal) => {
            panic!("Unsupported backend 'metal' for Windows");
        }
        (os, arch, api) => panic!("unsupported target: {os}/{arch} with backend '{api}'"),
    }
}

fn download_static(out_dir: &Path, revision: &str) -> CoreDownload {
    let graphics_api = GraphicsRenderingAPI::from_selected_features();

    let (lib_filename, link_name) = select_asset_name(graphics_api);

    let mut tasks = Vec::new();
    let library_file = out_dir.join(&lib_filename);
    if !library_file.is_file() {
        let static_url = format!("https://github.com/maplibre/maplibre-native/releases/download/{revision}/{lib_filename}");
        println!("cargo:warning=Downloading precompiled maplibre-native core library from {static_url} into {}", out_dir.display());
        tasks.push(Download::new(&static_url));
    }

    let headers_file = out_dir.join("maplibre-native-headers.tar.gz");
    if !headers_file.is_file() {
        let headers_url = format!("https://github.com/maplibre/maplibre-native/releases/download/{revision}/maplibre-native-headers.tar.gz");
        println!("cargo:warning=Downloading headers for maplibre-native core library from {headers_url} into {}", out_dir.display());
        tasks.push(Download::new(&headers_url));
    }
    fs::create_dir_all(out_dir).expect("Failed to create output directory");
    if tasks.is_empty() {
        return CoreDownload {
            library_file,
            headers_file,
            link_name,
        };
    }
    let max_attempts = 5u32;
    let mut last_error = String::new();

    for attempt in 1..=max_attempts {
        let mut downloader = Downloader::builder()
            .download_folder(out_dir)
            .parallel_requests(
                u16::try_from(tasks.len())
                    .expect("with the number of tasks, this cannot be exceeded"),
            )
            .build()
            .expect("Failed to create downloader");

        match downloader.download(&tasks) {
            Ok(downloads) => {
                let errors: Vec<String> = downloads
                    .into_iter()
                    .filter_map(|res| res.err().map(|err| err.to_string()))
                    .collect();

                if errors.is_empty() {
                    return CoreDownload {
                        library_file,
                        headers_file,
                        link_name,
                    };
                }

                last_error = errors.join("\n");
            }
            Err(err) => {
                last_error = err.to_string();
            }
        }

        if attempt < max_attempts {
            let backoff_secs = u64::from(attempt) * 5;
            println!(
                "cargo:warning=maplibre-native download attempt {attempt}/{max_attempts} failed, retrying in {backoff_secs}s"
            );
            std::thread::sleep(std::time::Duration::from_secs(backoff_secs));
        }
    }

    panic!("Unexpected error from downloader after {max_attempts} attempts: {last_error}");
}

/// Extracts the headers from the downloaded tarball
fn extract_headers(headers_from: &Path, headers_to: &Path) {
    println!(
        "cargo:warning=Extracting headers for maplibre-native core library from {} into {}",
        headers_from.display(),
        headers_to.display()
    );
    let headers_file = fs::File::open(headers_from).expect("Failed to open headers file");
    let mut tar = flate2::read::GzDecoder::new(headers_file);

    if !headers_to.is_dir() {
        fs::create_dir_all(headers_to).expect("Failed to create headers directory");
    }
    let mut archive = tar::Archive::new(&mut tar);
    archive.set_overwrite(true);
    archive
        .unpack(headers_to)
        .expect("Failed to extract headers");
}

/// Get local directory or download maplibre-native into the `OUT_DIR`
///
/// Returns the path to the maplibre-native directory and an optional path to an include directorys.
fn resolve_mln_core(root: &Path) -> (PathBuf, Vec<PathBuf>, String) {
    println!("cargo:rerun-if-env-changed=MLN_CORE_LIBRARY_PATH");
    // Backwards-compatible env var name (documented historically).
    println!("cargo:rerun-if-env-changed=MLN_CORE_HEADERS_PATH");
    // Preferred env var name (matches the other MLN_CORE_* variables).
    println!("cargo:rerun-if-env-changed=MLN_CORE_LIBRARY_HEADERS_PATH");

    let headers_env = env::var_os("MLN_CORE_LIBRARY_HEADERS_PATH")
        .or_else(|| env::var_os("MLN_CORE_HEADERS_PATH"));

    let (library_file, headers_file, link_name) =
        match (env::var_os("MLN_CORE_LIBRARY_PATH"), headers_env) {
            (Some(library_path), Some(headers_path)) => {
                let lib = PathBuf::from(library_path);
                let headers = PathBuf::from(headers_path);
                let link_name = derive_link_name(&lib);
                (lib, headers, link_name)
            }
            (Some(_), None) => panic!(
                "MLN_CORE_LIBRARY_HEADERS_PATH (or MLN_CORE_HEADERS_PATH) is not set. To compile from a local library/headers, both MLN_CORE_LIBRARY_PATH and a headers path must be set."
            ),
            (None, Some(_)) => panic!(
                "MLN_CORE_LIBRARY_PATH is not set. To compile from a local library/headers, both MLN_CORE_LIBRARY_PATH and a headers path must be set."
            ),
            // Default => download the precompiled static library.
            (None, None) => {
                println!("cargo:rerun-if-changed=Cargo.toml");
                let target_os = env::var("CARGO_CFG_TARGET_OS").expect("CARGO_CFG_TARGET_OS not set");
                let revision = select_mln_revision(root, &target_os);
                let cache_dir = default_mln_cache_dir(root).join(&revision);
                let dl = download_static(&cache_dir, &revision);
                (dl.library_file, dl.headers_file, dl.link_name)
            }
        };
    assert!(
        library_file.is_file(),
        "The MLN library at {} must be a file",
        library_file.display()
    );
    assert!(
        headers_file.is_file(),
        "The MLN headers at {} must be a file containing the headers archive",
        headers_file.display()
    );

    let extracted_path = headers_file
        .parent()
        .unwrap_or_else(|| panic!("headers file has no parent dir: {}", headers_file.display()))
        .join("headers");
    extract_headers(&headers_file, &extracted_path);
    // Returning the downloaded file, bypassing CMakeLists.txt check
    let include_dirs = vec![
        root.join("include"),
        extracted_path
            .join("vendor")
            .join("maplibre-native-base")
            .join("include"),
        extracted_path
            .join("vendor")
            .join("maplibre-native-base")
            .join("deps")
            .join("geometry.hpp")
            .join("include"),
        extracted_path
            .join("vendor")
            .join("maplibre-native-base")
            .join("deps")
            .join("variant")
            .join("include"),
        extracted_path.join("include"),
    ];
    (library_file, include_dirs, link_name)
}

/// Gather include directories and build the C++ bridge using `cxx_build`.
fn build_bridge(lib_name: &str, include_dirs: &[PathBuf]) {
    println!("cargo:rerun-if-changed=src/renderer/bridge.rs");
    println!("cargo:rerun-if-changed=include/map_renderer.h");
    println!("cargo:rerun-if-changed=include/rust_log_observer.h");
    cxx_build::bridge("src/renderer/bridge.rs")
        .includes(include_dirs)
        .file("src/renderer/bridge.cpp")
        // Keep Windows/MSVC headers sane.
        .define("NOMINMAX", None)
        .define("_USE_MATH_DEFINES", None)
        // GNU/Clang
        .flag_if_supported("-std=c++20")
        // MSVC
        .flag_if_supported("/std:c++20")
        .compile("maplibre_rust_map_renderer_bindings");

    // Link mbgl-core after the bridge - or else `cargo test` won't be able to find the symbols.
    println!("cargo:rustc-link-lib=static={lib_name}");
}

fn add_macos_link_search_paths() {
    // Check for Homebrew installation paths
    if let Ok(homebrew_prefix) = env::var("HOMEBREW_PREFIX") {
        println!("cargo:rustc-link-search=native={homebrew_prefix}/lib");
    } else if Path::new("/opt/homebrew").exists() {
        println!("cargo:rustc-link-search=native=/opt/homebrew/lib");
    } else if Path::new("/usr/local").exists() {
        println!("cargo:rustc-link-search=native=/usr/local/lib");
    }

    // macOS system library paths
    println!("cargo:rustc-link-search=native=/usr/lib");
    println!("cargo:rustc-link-search=native=/System/Library/Frameworks");

    // Add pkg-config paths if available
    if let Ok(pkgconfig_path) = env::var("PKG_CONFIG_PATH") {
        for path in pkgconfig_path.split(':') {
            let lib_path = Path::new(path).parent().map(|p| p.join("lib"));
            if let Some(lib_path) = lib_path {
                if lib_path.exists() {
                    println!("cargo:rustc-link-search=native={}", lib_path.display());
                }
            }
        }
    }
}

fn link_macos_deps() {
    // Non-amalgamated macOS core artefacts depend on system sqlite3 for caching.
    println!("cargo:rustc-link-lib=sqlite3");
    // libuv is used by mbgl::util::RunLoop and async task machinery.
    println!("cargo:rustc-link-lib=uv");
    // curl/z are available as system libs on macOS (and installed in CI via the just recipe).
    println!("cargo:rustc-link-lib=curl");
    println!("cargo:rustc-link-lib=z");
}

fn link_windows_deps() {
    // When building on Windows, the precompiled core library expects consumers to link against
    // several system and third-party libraries (libuv/sqlite/curl/zlib/ANGLE).
    //
    // We support vcpkg as the dependency provider. CI installs these via `just install-dependencies`.
    println!("cargo:rerun-if-env-changed=VCPKG_ROOT");
    println!("cargo:rerun-if-env-changed=VCPKG_INSTALLATION_ROOT");
    println!("cargo:rerun-if-env-changed=VCPKG_DEFAULT_TRIPLET");
    println!("cargo:rerun-if-env-changed=VCPKG_TARGET_TRIPLET");
    println!("cargo:rerun-if-env-changed=MLN_ICU_ROOT");

    let vcpkg_root = env::var("VCPKG_ROOT")
        .ok()
        .or_else(|| env::var("VCPKG_INSTALLATION_ROOT").ok());
    let triplet = env::var("VCPKG_TARGET_TRIPLET")
        .ok()
        .or_else(|| env::var("VCPKG_DEFAULT_TRIPLET").ok())
        .unwrap_or_else(|| "x64-windows".to_string());
    if let Some(root) = vcpkg_root {
        println!("cargo:rustc-link-search=native={root}/installed/{triplet}/lib");
        println!("cargo:rustc-link-search=native={root}/installed/{triplet}/bin");
    } else {
        println!("cargo:warning=VCPKG_ROOT/VCPKG_INSTALLATION_ROOT not set; Windows linking may fail unless dependencies are discoverable by the linker");
    }

    let mut icu_link_dirs: Vec<PathBuf> = Vec::new();
    if let Ok(icu_root) = env::var("MLN_ICU_ROOT") {
        // ICU build output layout differs by build system.
        // The MSVC allinone build typically places import libs in `lib64` and DLLs in `bin64`,
        // but some setups nest by configuration (e.g. `lib64/Release`).
        let root = PathBuf::from(&icu_root);
        icu_link_dirs.extend(collect_icu_link_dirs(&root));
        for dir in &icu_link_dirs {
            println!("cargo:rustc-link-search=native={}", dir.display());
        }
    } else {
        println!("cargo:warning=MLN_ICU_ROOT not set; Windows linking will fail if ICU is not otherwise discoverable");
    }

    // Third-party deps
    println!("cargo:rustc-link-lib=uv");
    println!("cargo:rustc-link-lib=sqlite3");
    println!("cargo:rustc-link-lib=zlib");
    println!("cargo:rustc-link-lib=libcurl");
    // Image decoding deps used by core.
    println!("cargo:rustc-link-lib=libpng16");
    println!("cargo:rustc-link-lib=jpeg");
    println!("cargo:rustc-link-lib=libwebp");
    // ICU deps used by core (BiDi/shaping). The published Windows core expects ICU 61.x.
    emit_windows_icu_libs(&icu_link_dirs);
    // ANGLE: EGL + GLES2 for headless rendering
    println!("cargo:rustc-link-lib=libEGL");
    println!("cargo:rustc-link-lib=libGLESv2");

    // Common system libs needed by the above deps.
    println!("cargo:rustc-link-lib=ws2_32");
    println!("cargo:rustc-link-lib=crypt32");
    println!("cargo:rustc-link-lib=bcrypt");
    println!("cargo:rustc-link-lib=advapi32");
    println!("cargo:rustc-link-lib=secur32");
    println!("cargo:rustc-link-lib=normaliz");
    println!("cargo:rustc-link-lib=user32");
    println!("cargo:rustc-link-lib=gdi32");
    println!("cargo:rustc-link-lib=shell32");
    println!("cargo:rustc-link-lib=ole32");
    println!("cargo:rustc-link-lib=shlwapi");
}

fn collect_icu_link_dirs(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();

    // Some build setups set MLN_ICU_ROOT to `.../source`, but the VS projects may output to its parent
    // (or vice versa). Search both to be robust.
    let mut roots: Vec<PathBuf> = vec![root.to_path_buf()];
    if let Some(parent) = root.parent() {
        roots.push(parent.to_path_buf());
    }

    for r in &roots {
        // Directories we expect from ICU source builds.
        let top_level_candidates = ["lib64", "lib", "bin64", "bin"];
        for sub in top_level_candidates {
            let p = r.join(sub);
            if p.is_dir() {
                out.push(p);
            }
        }

        // Also include any top-level dirs starting with `lib`/`bin` that we might not have anticipated.
        if let Ok(entries) = fs::read_dir(r) {
            for entry in entries.flatten() {
                let p = entry.path();
                if !p.is_dir() {
                    continue;
                }
                let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if (name.starts_with("lib") || name.starts_with("bin")) && !out.contains(&p) {
                    out.push(p);
                }
            }
        }
    }

    // Some MSBuild layouts nest by configuration.
    let config_candidates = ["Release", "Debug"];
    let mut nested: Vec<PathBuf> = Vec::new();
    for base in &out {
        for cfg in config_candidates {
            let p = base.join(cfg);
            if p.is_dir() {
                nested.push(p);
            }
        }
    }
    out.extend(nested);

    // De-dup while keeping order.
    let mut dedup: Vec<PathBuf> = Vec::new();
    for p in out {
        if !dedup.contains(&p) {
            dedup.push(p);
        }
    }

    if !dedup.is_empty() {
        return dedup;
    }

    // Fallback: some ICU build layouts don't place import libs in predictable top-level `lib*/` dirs.
    // Walk the tree and collect directories that actually contain icu*.lib files.
    //
    // This is a last resort because it can be expensive on large source trees, but it makes
    // CI resilient across ICU project output layout changes.
    let mut discovered: Vec<PathBuf> = Vec::new();
    for r in &roots {
        discovered.extend(discover_icu_link_dirs(r));
    }
    // De-dup while keeping order.
    let mut dedup: Vec<PathBuf> = Vec::new();
    for p in discovered {
        if !dedup.contains(&p) {
            dedup.push(p);
        }
    }
    dedup
}

fn discover_icu_link_dirs(root: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    // ICU outputs are usually shallow, but give enough depth to cover nested MSBuild layouts.
    let walker = WalkDir::new(root).follow_links(false).max_depth(12);
    for entry in walker.into_iter().filter_map(Result::ok) {
        if !entry.file_type().is_file() {
            continue;
        }
        let p = entry.path();
        let Some(ext) = p.extension().and_then(|e| e.to_str()) else {
            continue;
        };
        if !ext.eq_ignore_ascii_case("lib") {
            continue;
        }
        let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if !looks_like_windows_icu_lib(stem) {
            continue;
        }
        let Some(parent) = p.parent() else {
            continue;
        };
        if !dirs.contains(&parent.to_path_buf()) {
            dirs.push(parent.to_path_buf());
        }
    }
    dirs
}

fn looks_like_windows_icu_lib(stem: &str) -> bool {
    let stem = stem.to_ascii_lowercase();
    for base in ["icuuc", "icuin", "icudt", "sicuuc", "sicuin", "sicudt"] {
        if stem == base {
            return true;
        }
        if let Some(rest) = stem.strip_prefix(base) {
            if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
                return true;
            }
        }
    }
    false
}

fn pick_windows_icu_lib(link_dirs: &[PathBuf], base: &str) -> Option<String> {
    let mut candidates: Vec<String> = Vec::new();
    for dir in link_dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            if !p.is_file() {
                continue;
            }
            let Some(ext) = p.extension().and_then(|e| e.to_str()) else {
                continue;
            };
            if !ext.eq_ignore_ascii_case("lib") {
                continue;
            }
            let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if stem.eq_ignore_ascii_case(base) {
                candidates.push(stem.to_string());
                continue;
            }
            // ICU commonly uses version-suffixed libs on Windows (e.g. icuuc61.lib).
            if let Some(rest) = stem.strip_prefix(base) {
                if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
                    candidates.push(stem.to_string());
                }
            }
        }
    }

    if candidates.is_empty() {
        return None;
    }

    // Prefer ICU 61 (maplibre-native Windows core currently expects 61.x symbols).
    let want = format!("{base}61");
    if let Some(hit) = candidates.iter().find(|s| s.eq_ignore_ascii_case(&want)) {
        return Some(hit.clone());
    }

    // Otherwise prefer the unversioned name.
    if let Some(hit) = candidates.iter().find(|s| s.eq_ignore_ascii_case(base)) {
        return Some(hit.clone());
    }

    // Otherwise pick a stable choice.
    candidates.sort();
    Some(candidates[0].clone())
}

fn emit_windows_icu_libs(icu_link_dirs: &[PathBuf]) {
    // If the user didn't provide ICU, keep previous behavior; it will fail loudly in CI.
    if icu_link_dirs.is_empty() {
        println!("cargo:rustc-link-lib=icuuc");
        println!("cargo:rustc-link-lib=icuin");
        println!("cargo:rustc-link-lib=icudt");
        return;
    }

    for base in ["icuuc", "icuin", "icudt"] {
        if let Some(name) = pick_windows_icu_lib(icu_link_dirs, base) {
            println!("cargo:rustc-link-lib={name}");
        } else if let Some(name) = pick_windows_icu_lib(icu_link_dirs, &format!("s{base}")) {
            // Some ICU builds produce only static libs with an `s` prefix.
            println!("cargo:warning=Could not find {base}*.lib under MLN_ICU_ROOT link dirs; using static {name}");
            println!("cargo:rustc-link-lib={name}");
        } else {
            // Fall back to the conventional name; this makes the error obvious.
            println!("cargo:warning=Could not find {base}*.lib under MLN_ICU_ROOT link dirs; falling back to {base}");
            println!("cargo:rustc-link-lib={base}");
        }
    }
}

fn link_linux_deps() {
    // The linux amalgamated core artefacts expect consumers to link several system libs.
    // These are provided by apt on CI via `just install-dependencies`.
    println!("cargo:rustc-link-lib=uv");
    println!("cargo:rustc-link-lib=jpeg");
    println!("cargo:rustc-link-lib=png");
    println!("cargo:rustc-link-lib=webp");
    println!("cargo:rustc-link-lib=curl");
    println!("cargo:rustc-link-lib=z");
}

fn link_graphics_deps(api: GraphicsRenderingAPI, target_os: &str) {
    match api {
        GraphicsRenderingAPI::Vulkan => {
            // Vulkan shader compilation in the core uses glslang on Linux.
            if target_os == "linux" {
                println!("cargo:rustc-link-lib=glslang");
                println!("cargo:rustc-link-lib=SPIRV");
                println!("cargo:rustc-link-lib=glslang-default-resource-limits");
                // glslang is built against SPIRV-Tools on Ubuntu and requires it for optimization/disassembly.
                println!("cargo:rustc-link-lib=SPIRV-Tools-opt");
                // Note: order matters for static archives on older linkers (MSRV). `-opt` depends on `SPIRV-Tools`.
                println!("cargo:rustc-link-lib=SPIRV-Tools");
            } else if target_os == "windows" {
                // Link against the Vulkan loader import library when using the Vulkan backend.
                println!("cargo:rustc-link-lib=vulkan-1");
                // The precompiled Windows Vulkan core also expects glslang/SPIR-V toolchain symbols.
                println!("cargo:rustc-link-lib=glslang");
                println!("cargo:rustc-link-lib=SPIRV");
                println!("cargo:rustc-link-lib=glslang-default-resource-limits");
                // vcpkg glslang is split into multiple static archives on Windows.
                println!("cargo:rustc-link-lib=MachineIndependent");
                println!("cargo:rustc-link-lib=GenericCodeGen");
                println!("cargo:rustc-link-lib=OSDependent");
                println!("cargo:rustc-link-lib=SPVRemapper");
                println!("cargo:rustc-link-lib=SPIRV-Tools-opt");
                println!("cargo:rustc-link-lib=SPIRV-Tools");
            }
        }
        GraphicsRenderingAPI::OpenGL => {
            if target_os != "windows" {
                println!("cargo:rustc-link-lib=GL");
                println!("cargo:rustc-link-lib=EGL");
            }
        }
        GraphicsRenderingAPI::Metal => {
            // macOS Metal framework dependencies
            println!("cargo:rustc-link-lib=framework=Metal");
            println!("cargo:rustc-link-lib=framework=MetalKit");
            println!("cargo:rustc-link-lib=framework=QuartzCore");
            println!("cargo:rustc-link-lib=framework=Foundation");
            println!("cargo:rustc-link-lib=framework=CoreGraphics");
            println!("cargo:rustc-link-lib=framework=AppKit");
            println!("cargo:rustc-link-lib=framework=CoreLocation");
        }
    }
}

fn build_mln() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let (cpp_root, include_dirs, link_name) = resolve_mln_core(&root);
    println!(
        "cargo:warning=Using precompiled maplibre-native static library from {}",
        cpp_root.display()
    );
    println!(
        "cargo:rustc-link-search=native={}",
        cpp_root.parent().unwrap().display()
    );

    let target_os = env::var("CARGO_CFG_TARGET_OS").expect("CARGO_CFG_TARGET_OS not set");
    if target_os == "macos" {
        add_macos_link_search_paths();
    }

    // These `cargo:rustc-link-lib` must be done before curl and GL,
    // especially on Linux before 1.90 (1.90 introduced new linker on Linux)
    build_bridge(&link_name, &include_dirs);

    if target_os == "macos" {
        link_macos_deps();
    } else if target_os == "windows" {
        link_windows_deps();
    } else {
        link_linux_deps();
    }

    let graphics_api = GraphicsRenderingAPI::from_selected_features();
    link_graphics_deps(graphics_api, &target_os);
}

fn main() {
    println!("cargo:rerun-if-env-changed=DOCS_RS");
    if env::var("DOCS_RS").is_ok() {
        println!("cargo:warning=Skipping build.rs when building for docs.rs");
        println!("cargo::rustc-cfg=docsrs");
        println!("cargo:rustc-check-cfg=cfg(docsrs)");
    } else {
        build_mln();
    }
}
