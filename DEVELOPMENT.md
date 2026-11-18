# Development

This document describes aspects of the project relevant to developers of Tinny
itself.

## Running CI checks locally

Every CI check is a [mise] task, and CI runs exactly those tasks, so what passes
locally passes in CI. With mise installed, `mise install` fetches the pinned tools
(git-cliff, cargo-deny, cargo-semver-checks, actionlint, zizmor, shellcheck); the
Rust toolchain comes from `rust-toolchain.toml` via rustup.

```sh
# Everything, cheapest first, stopping at the first failure
mise run ci

# The same, against the commit a release of HEAD would create (see below).
# Fetch first, so the base branch and tags are current.
git fetch origin --tags
mise run ci:release-preview
```

Or one stage at a time, in the order CI runs them:

| Task | Runs |
|---|---|
| `mise run lint` | `workflow-lint` (actionlint, zizmor), `shellcheck`, `fmt`, `deny` (cargo-deny), `clippy` |
| `mise run test` | `cargo test` |
| `mise run docs` | `cargo doc`, denying warnings |
| `mise run semver` | cargo-semver-checks: does the version cover the public-API changes since the last published release? |
| `mise run publish-dry-run` | `cargo publish --dry-run` |
| `mise run package [TARGET]` | tests for TARGET (default: the host), its release build, and its archive in `target/package/` |

`mise run ci` checks your working tree as it is, so two stages say less there than in
CI: `semver` compares against an unbumped version, and `publish-dry-run`, like `cargo
publish`, refuses uncommitted changes and warns that the version is already published.
`ci:release-preview` checks what CI checks, but from your last commit.

`package` runs what it builds, so it only handles targets your machine can run: CI
packages each target on a matching runner (arm64 Linux included). Other targets need
`rustup target add TARGET`, and `x86_64-unknown-linux-musl` needs musl-tools.

`mise run prepare` makes the release commit on its own: HEAD rebased onto
`origin/HEAD` (or `origin/$RELEASE_BASE_BRANCH`, or `--base REF`), version bumped,
`CHANGELOG.md` updated, tagged. It works in a clone under `target/release-preview/`,
so your checkout, branches and tags are never touched.

## Build and Release

Releasing is automated, driven by conventional commits: nobody manually bumps
`Cargo.toml`, writes `CHANGELOG.md`, creates a tag, or runs `cargo publish`. Every
merge is a release.

### Build (`.github/workflows/build.yaml`)

Runs on every push. It doesn't check the branch as pushed, but the commit a release
of it would create: [`scripts/prepare-release.sh`](scripts/prepare-release.sh)
rebases it onto the base branch (the `RELEASE_BASE_BRANCH` repository variable, or
the default branch), sets the version [git-cliff] computes from the commits since
the last release (or a higher one already in `Cargo.toml`), updates `CHANGELOG.md`,
commits and tags. That fails if the branch doesn't rebase cleanly, if any commit
isn't conventional, or if the version is already tagged or on crates.io. Then,
cheapest first, each stage only if the last passed:

1. `prepare`
2. `lint`
3. `test`, `docs`, `semver`, `publish-dry-run`
4. `package`, for each release target, including a check that `can --version`
   reports the release version (build.rs's release-build path)

Every cargo command uses `--locked`, so the branch's `Cargo.lock` is what gets built
and released; prepare only changes our own package's version in it.

### Release (`.github/workflows/release.yml`)

When a PR is ready, go to **Actions → Release → Run workflow**, choose the PR's base
branch under "Use workflow from", and enter the PR number. The workflow:

1. checks the PR is open, not a draft, not from a fork, and targets the branch the
   workflow was run from;
2. runs the whole build workflow again, from scratch, on the PR's current head;
3. in the `publish` job (the `release` environment):
   1. fast-forwards the base branch to the release commit and pushes its tag,
      atomically;
   2. points the PR's branch at the release commit, which makes GitHub mark the PR
      merged (if the branch has moved on, it closes the PR with a comment instead);
   3. attests build provenance for the archives;
   4. creates a **draft** GitHub Release with the archives, their checksums, and
      the version's changelog section;
   5. publishes to crates.io (trusted publishing: no stored token);
   6. publishes the GitHub Release.

Releases run one at a time. If the base branch moved since step 2 started, the push
fails and nothing has been released: run the workflow again. If anything after the
push fails, fix the cause and re-run the `publish` job: every step skips whatever it
already did.

### What the release trusts

Nothing from the PR's own build runs. The release workflow, the build workflow it
calls and every action they use are read from the base branch: the run comes from
it, and `uses: $/...` loads in-repo actions from the workflow's own commit, whatever
is checked out. So a PR that changes CI is released under the base branch's CI (its
own pushes still exercise its version).

The PR's code does run during verification (build.rs, tests, and the tools its
`mise.toml` pins), but with read-only repository access, no secrets, no OIDC, and
no caches. Caches matter because a release run has the base branch's cache scope:
anything its jobs saved could be restored into a later release's builds.

The `publish` job has the secrets, so it never builds or runs the PR's code, nor
lets config from the PR's tree steer a tool: cargo uses the base branch's toolchain
(the PR's `rust-toolchain.toml` could name any binary), the release notes come from
prepare rather than running git-cliff on the PR's `cliff.toml`, and it refuses to run
`cargo publish` at all if the tree has a `.cargo/config.toml`, which could change how
cargo authenticates. A signing key would go in the `release` environment, used by a
step after the archives are downloaded and verified.

### One-time setup

- A GitHub App, installed on this repository, with read and write access to
  contents and pull requests. It pushes to the protected base branch.
- A `release` environment, limited to the base branches (`main`, `crate-testing`),
  with the App's client ID as variable `RELEASE_APP_CLIENT_ID` and its private key as
  secret `RELEASE_APP_PRIVATE_KEY`.
- A ruleset on the base branches: require a pull request, require linear history,
  block force pushes and deletion, with the App allowed to bypass. Then a release is
  the only way onto them.
- crates.io trusted publishing for the crate: repository `the-goatfish/tinny`,
  workflow `release.yml`, environment `release`.
- Optionally, a `RELEASE_BASE_BRANCH` repository variable, if branches should be
  checked against something other than the default branch.

[mise]: https://mise.jdx.dev/
[git-cliff]: https://git-cliff.org/

## Versioning

This project contains a number of different parts, and therefore the versioning
can seem complicated. There are 3 distinct versions.

1. The Tinny Cargo package version
2. The Can file schema version
3. The Tinny web user-interface (WUI) version

The Tinny version as it appears in the `Cargo.toml` in Git, GitHub Releases, and
Cargo refers to the Cargo package, which is mainly about the library. The `can`
_binary_ is part of that package and so shares that version. This version follows
[semantic versioning][semver].

The `can.yaml` file schema has it's own version which appears inside the file.
This version is a simple number.

The web user-interface (WUI) is a Node package which is compiled and bundled as
a static website into the `dist` directory. When the Tinny package is built, whatever
is in that directory is included in the package, and embedded at compile time into
the Tinny library crate; thus it has its own [semantic version][semver].

### Automatic Versioning

Tinny's version is calculated at build time from the build environment,
the repository, and the working directory.

#### Cargo Package or Dependency

These two contexts always use the version as written in `Cargo.toml`, with no bump
or pre-release tag. It needs only a Rust/Cargo toolchain.

* **Packaging** — `cargo package`/`cargo publish` (including its own dry-run
  verification build), or building an already-packaged/vendored source tree (e.g.
  `cargo install`, since a downloaded `.crate` has no `.git`). Detected by
  [`.cargo_vcs_info.json`][cargo_vcs_info] being present at the crate root, or more
  generally by there being no `.git` working directory (or no `git` tool) to ask.
* **Consumption as a dependency** — tinny being built as a dependency inside someone
  else's `Cargo.toml`, not as the package they're directly building. Detected by the
  absence of Cargo's [`CARGO_PRIMARY_PACKAGE`][cargo_primary_package] build-script
  environment variable, which Cargo sets only for packages being built directly.

Build metadata may still be attached opportunistically here from `.cargo_vcs_info.json`
(see below) — SemVer build metadata never affects a version's precedence, so attaching
it doesn't alter the version's meaning.

#### Other builds

Every other `cargo build`/`test`/`run` a contributor or CI job runs inside a checkout
of this repository defaults to a **pre-release** version: a bump attempt, a pre-release
tag, and build metadata. The one exception is the **release build**: HEAD is exactly at
a tag matching `CARGO_PKG_VERSION`, and the working tree is clean. That's the state the
GitHub release pipeline leaves the repository in immediately after tagging, which only
happens once every check has passed (see `scripts/prepare-release.sh`, which bumps and
tags, and `release.yml`, which pushes and publishes) — nobody reaches it by accident.
There, and only there, the version is exactly `CARGO_PKG_VERSION`, with no pre-release
tag: the official release version.

If `git` isn't available at all, or there's no Git working directory to inspect, this
whole section is moot and we get the same plain outcome as above.

#### Tools

Two external CLIs are used opportunistically, each detected independently by attempting
to invoke it (a failed spawn or non-zero exit counts as "not available"):

* `git` — read-only repository introspection (HEAD hash, dirty state, commit timestamp,
  tags). Needed for everything in this section, including the plain-build checks above.
* `git-cliff` — computing a conventional-commits version bump. Only consulted once `git`
  has confirmed this isn't a plain or release build.

Both are invoked as subprocesses; automatic versioning works whether or not these
happen to be installed, and the plain-build paths must never need to compile or link
them at all.

#### Build metadata (`+...`)

Tried in this order, independently of everything else in this section:

1. **[`.cargo_vcs_info.json`][cargo_vcs_info]**, if present — its `git.sha1` and
   `git.dirty` fields. This is what makes build metadata available even for a packaging
   build, or for anyone who later `cargo install`s or vendors the published crate, with
   no `.git` directory in sight.
2. Otherwise, if `git` is available and this is a Git working directory: the HEAD
   commit's short hash and whether the tree is dirty (uncommitted or untracked changes),
   read from `git` directly.
3. Otherwise: no build metadata is attached.

When both a commit hash and a CI-native build reference are available (e.g. GitHub
Actions' `GITHUB_RUN_ID`+`GITHUB_RUN_ATTEMPT`), prefer the CI-native reference, to
disambiguate repeated builds of the same commit.

#### Version core and pre-release tag

1. If `git` isn't available, or there's no Git working directory: plain outcome —
   `CARGO_PKG_VERSION`, no pre-release (same as a plain build above; this is also what
   happens if a packaging build somehow reaches this point at all, since it will already
   have been caught above).
2. If HEAD is exactly at a tag matching `CARGO_PKG_VERSION`, and the tree is clean:
   **release build** — `major.minor.patch` = `CARGO_PKG_VERSION`, no pre-release.
3. Otherwise, this is a development build, always pre-release:
   * If `git-cliff` is available, run `git-cliff --bumped-version` to get the next
     semantic version implied by conventional commits since the last tag; this becomes
     `major.minor.patch`.
   * If `git-cliff` isn't available, increment the patch by one and use
     `max(candidate, CARGO_PKG_VERSION)` as `major.minor.patch` (ordinary SemVer
     precedence comparison). This needs only `git` and guarantees the result always
     sorts after the last real release regardless of whether Cargo.toml has been
     manually bumped yet on this branch, while still honouring a manual minor/major
     bump already committed. If no tag is reachable at all, fall back to
     `CARGO_PKG_VERSION` unchanged.
   * **Pre-release identifier**: the HEAD commit's timestamp (commit time if clean,
     build time if dirty, so a dirty rebuild always sorts later than the last clean one),
     formatted so pre-release identifiers still order correctly.

#### Assembly

`{major.minor.patch}` + (`-{prerelease}` if this was a development build) +
(`+{buildmeta}` if any source above produced one).

[semver]: https://semver.org/
[cargo_vcs_info]: https://doc.rust-lang.org/cargo/commands/cargo-package.html#cargo_vcs_infojson-format
[cargo_primary_package]: https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts
