use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use semver::{BuildMetadata, Prerelease, Version};

fn main() {
    let version = calculate_version();
    println!("cargo:rustc-env=CARGO_PKG_VERSION={}", version);
}

/// Helpers for deriving one `Version` from another without going through a raw
/// string: every intermediate value stays a `semver` type, so an invalid piece
/// (an ill-formed prerelease or build-metadata string) is rejected the moment
/// it would be constructed, not whenever the result is later parsed or printed.
trait VersionExt {
    /// `major.minor.patch` only — drops any existing prerelease/build metadata.
    fn core_only(&self) -> Version;
    /// `major.minor.(patch + 1)`, bare (no prerelease/build metadata).
    fn bumped_patch(&self) -> Version;
    fn with_prerelease(self, pre: Prerelease) -> Version;
    fn with_build_metadata(self, meta: Option<BuildMetadata>) -> Version;
}

impl VersionExt for Version {
    fn core_only(&self) -> Version {
        Version::new(self.major, self.minor, self.patch)
    }

    fn bumped_patch(&self) -> Version {
        Version::new(self.major, self.minor, self.patch + 1)
    }

    fn with_prerelease(mut self, pre: Prerelease) -> Version {
        self.pre = pre;
        self
    }

    fn with_build_metadata(mut self, meta: Option<BuildMetadata>) -> Version {
        if let Some(meta) = meta {
            self.build = meta;
        }
        self
    }
}

/// Computes Tinny's version per the algorithm described in DEVELOPMENT.md. See that
/// document for the reasoning behind each step; this is a direct implementation of it.
fn calculate_version() -> Version {
    let pkg_version: Version = env!("CARGO_PKG_VERSION")
        .parse()
        .expect("CARGO_PKG_VERSION set by Cargo must be valid semver");

    // Consumed as a dependency: we're not the package being built directly.
    //
    // `CARGO_PRIMARY_PACKAGE` is only set when *compiling* a crate (Cargo does not
    // forward it into a build script's own runtime environment), so it has to be read
    // with `option_env!` — a compile-time check baked in when this build script itself
    // is compiled — rather than `std::env::var` at build-script runtime.
    if option_env!("CARGO_PRIMARY_PACKAGE").is_none() {
        let meta = build_metadata(cargo_vcs_info().map(|i| (i.sha1, i.dirty)));
        return pkg_version.with_build_metadata(meta);
    }

    // Packaging: `cargo package`/`cargo publish` (including its own dry-run
    // verification build), or a build of an already-packaged/vendored source tree.
    if let Some(info) = cargo_vcs_info() {
        let meta = build_metadata(Some((info.sha1, info.dirty)));
        return pkg_version.with_build_metadata(meta);
    }
    if !Path::new(".git").exists() {
        return pkg_version;
    }

    // Everything else: automatic versioning, on by default.
    dynamic_version(pkg_version)
}

struct VcsInfo {
    sha1: String,
    dirty: bool,
}

/// Reads `.cargo_vcs_info.json`, if present. `cargo package`/`cargo publish` write this
/// file into the `.crate` itself, so it's the source of build metadata for a packaging
/// build (and for anyone who later `cargo install`s or vendors the published crate) even
/// though there's no `.git` directory to ask. `serde_json` is already a mandatory
/// dependency of the crate itself, so using it here adds no new requirement beyond what
/// any build of tinny already needs.
fn cargo_vcs_info() -> Option<VcsInfo> {
    let content = fs::read_to_string(".cargo_vcs_info.json").ok()?;
    let value: serde_json::Value = serde_json::from_str(&content).ok()?;
    let git = value.get("git")?;
    let sha1 = git.get("sha1")?.as_str()?.to_string();
    let dirty = git.get("dirty").and_then(|d| d.as_bool()).unwrap_or(false);
    Some(VcsInfo { sha1, dirty })
}

/// Build metadata (the `+...` suffix): a CI-native build reference when present (to
/// disambiguate repeated builds of the same commit), otherwise the given commit hash
/// (with a `.dirty` suffix if the tree was dirty), otherwise none.
fn build_metadata(commit: Option<(String, bool)>) -> Option<BuildMetadata> {
    let raw = ci_build_ref().or_else(|| {
        commit.map(|(hash, dirty)| if dirty { format!("{hash}.dirty") } else { hash })
    })?;
    Some(
        BuildMetadata::new(&raw)
            .expect("generated build metadata must be valid semver build-metadata"),
    )
}

fn ci_build_ref() -> Option<String> {
    let id = env::var("GITHUB_RUN_ID").ok()?;
    let attempt = env::var("GITHUB_RUN_ATTEMPT").ok()?;
    Some(format!("{id}.{attempt}"))
}

/// The "every other build" path: always a pre-release unless HEAD is exactly at a tag
/// matching `CARGO_PKG_VERSION` on a clean tree (the release build). `git` and
/// `git-cliff` are both optional external tools, each detected independently by
/// attempting to invoke it; the absence of either degrades the result, never breaks the
/// build.
fn dynamic_version(pkg_version: Version) -> Version {
    if !tool_available("git") || !in_git_worktree() {
        return pkg_version;
    }

    let dirty = git_is_dirty();
    let hash = git_short_hash();
    let meta = build_metadata(hash.map(|h| (h, dirty)));

    if !dirty
        && let Some(tag) = git_exact_tag()
        && Version::parse(&normalize_tag(&tag)).ok().as_ref() == Some(&pkg_version)
    {
        return pkg_version.with_build_metadata(meta);
    }

    let pkg_core = pkg_version.core_only();

    let core = if tool_available("git-cliff") {
        git_cliff_bumped_version()
            .and_then(|v| Version::parse(&v).ok())
            .map(|v| v.core_only())
            .unwrap_or_else(|| pkg_core.clone())
    } else {
        let candidate = git_last_tag()
            .and_then(|t| Version::parse(&normalize_tag(&t)).ok())
            .map(|v| v.bumped_patch());
        match candidate {
            Some(c) if c >= pkg_core => c,
            _ => pkg_core.clone(),
        }
    };

    let prerelease = if dirty {
        now_epoch()
    } else {
        git_commit_epoch().unwrap_or_else(now_epoch)
    };
    let pre = Prerelease::new(&format!("pre.{prerelease}"))
        .expect("generated prerelease identifier must be valid semver prerelease");

    core.with_prerelease(pre).with_build_metadata(meta)
}

fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(cmd).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8(output.stdout).ok()?;
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn tool_available(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn in_git_worktree() -> bool {
    Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn git_is_dirty() -> bool {
    Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=all"])
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false)
}

fn git_short_hash() -> Option<String> {
    run("git", &["rev-parse", "--short=7", "HEAD"])
}

fn git_commit_epoch() -> Option<u64> {
    run("git", &["show", "-s", "--format=%ct", "HEAD"])?
        .parse()
        .ok()
}

fn git_exact_tag() -> Option<String> {
    run("git", &["describe", "--tags", "--exact-match", "HEAD"])
}

fn git_last_tag() -> Option<String> {
    run("git", &["describe", "--tags", "--abbrev=0"])
}

fn git_cliff_bumped_version() -> Option<String> {
    run("git-cliff", &["--bumped-version"]).map(|v| normalize_tag(&v))
}

fn normalize_tag(tag: &str) -> String {
    tag.strip_prefix('v')
        .or_else(|| tag.strip_prefix('V'))
        .unwrap_or(tag)
        .to_string()
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
