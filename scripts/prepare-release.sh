#!/usr/bin/env bash
# Creates the commit the release workflow would push for a branch: rebased onto
# the base branch, with the version bumped, CHANGELOG.md updated, and tagged
# vX.Y.Z. It all happens in a throwaway clone (sharing objects with this one),
# so the calling repository's checkout, branches and tags are never touched.
#
# The build workflow runs this on every push and then checks the result; the
# release workflow runs it again, checks again, and pushes it. Locally, run it
# with `mise run prepare` or `mise run ci:release-preview` (fetch first, so the
# base and tags are current).
#
# Usage: scripts/prepare-release.sh [--base REF] [--head REV] [--out DIR]
#
#   --base  ref to rebase onto (default: origin/$RELEASE_BASE_BRANCH if that's
#           set, as the build workflow's repository variable is; otherwise
#           origin/HEAD, e.g. origin/main)
#   --head  commit to release (default: HEAD)
#   --out   output directory (default: target/release-preview)
#
# Writes to DIR:
#   repo/             clone checked out at the prepared commit
#   prepared.bundle   git bundle of HEAD and the tag, for other CI jobs
#   version           the version (no leading v)
#   released          "true" if a release commit was made; "false" if the
#                     rebased head is already the tagged release of `version`
#   release-notes.md  this version's changelog section, for the GitHub Release
set -euo pipefail

die() {
    echo "prepare-release: $*" >&2
    exit 1
}

# Whether core version (major.minor.patch) $1 is greater than $2.
core_gt() {
    local a=${1%%[-+]*} b=${2%%[-+]*}
    [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

base='' head=HEAD out=target/release-preview
while [ $# -gt 0 ]; do
    case "$1" in
        --base) base=${2:?--base needs a value}; shift 2 ;;
        --head) head=${2:?--head needs a value}; shift 2 ;;
        --out) out=${2:?--out needs a value}; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
if [ -z "$base" ] && [ -n "${RELEASE_BASE_BRANCH:-}" ]; then
    base=origin/$RELEASE_BASE_BRANCH
elif [ -z "$base" ]; then
    base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD) ||
        die "no --base given and origin/HEAD is unset (try: git remote set-head origin --auto)"
fi
head_sha=$(git rev-parse --verify --quiet "$head^{commit}") || die "unknown head: $head"
base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "unknown base: $base"

mkdir -p "$out"
out=$(cd "$out" && pwd -P)
rm -rf "$out/repo" "$out/prepared.bundle" "$out/version" "$out/released" "$out/release-notes.md"
# Not a worktree: those share refs, and the tag created below must stay local
# to the clone.
git clone --quiet --shared --no-checkout "$(git rev-parse --show-toplevel)" "$out/repo"
cd "$out/repo"
git checkout --quiet --detach "$head_sha"
# So mise's shims use the prepared tree's pinned tools (mise refuses untrusted
# config files). Everything below runs the prepared tree's code anyway.
export MISE_TRUSTED_CONFIG_PATHS="$out/repo${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"

# Rebased commits keep their authors; this identity is the committer, and the
# author of the release commit.
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-github-actions[bot]}
export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
export GIT_AUTHOR_NAME=$GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL=$GIT_COMMITTER_EMAIL

echo "Rebasing $head ($head_sha) onto $base ($base_sha)" >&2
if ! git rebase --quiet "$base_sha"; then
    git rebase --abort || true
    die "$head doesn't rebase cleanly onto $base; rebase it yourself and push"
fi

metadata=$(cargo metadata --no-deps --format-version 1)
name=$(jq -r '.packages[0].name' <<<"$metadata")
pkg_version=$(jq -r '.packages[0].version' <<<"$metadata")

if [ "$(git describe --tags --exact-match HEAD 2>/dev/null)" = "v$pkg_version" ]; then
    # Typically a push to the base branch itself, just after a release.
    version=$pkg_version tag=v$pkg_version released=false
    echo "$head rebased onto $base is already release $tag; nothing to prepare" >&2
else
    # cliff.toml sets fail_on_unmatched_commit, so this fails on any commit
    # that isn't conventional, naming it.
    git-cliff --offline --unreleased >/dev/null ||
        die "git-cliff can't generate a changelog for the unreleased commits (see above)"

    version=$(git-cliff --offline --bumped-version)
    version=${version#v}
    # Honour a manual bump in Cargo.toml beyond what the commits imply (e.g.
    # 1.0.0), as build.rs does.
    if core_gt "$pkg_version" "$version"; then
        version=$pkg_version
    fi
    tag=v$version
    if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
        die "$tag already exists, but isn't $head rebased onto $base"
    fi

    status=$(curl -sS -o /dev/null -w '%{http_code}' \
        -A "tinny-release (https://github.com/the-goatfish/tinny)" \
        "https://crates.io/api/v1/crates/$name/$version") || die "couldn't reach crates.io"
    case "$status" in
        404) ;;
        200) die "$name $version is already on crates.io" ;;
        *) die "unexpected HTTP $status from crates.io checking for $name $version" ;;
    esac

    awk -v v="$version" '!done && /^version = "/ { print "version = \"" v "\""; done = 1; next } { print }' \
        Cargo.toml >Cargo.toml.new
    mv Cargo.toml.new Cargo.toml
    [ "$(cargo metadata --no-deps --format-version 1 | jq -r '.packages[0].version')" = "$version" ] ||
        die "couldn't set the [package] version in Cargo.toml"
    # Only refreshes our own entry: the release builds with the branch's Cargo.lock.
    cargo update --quiet --workspace
    if git diff -U0 -- Cargo.lock | grep -E '^[-+][^-+]' | grep -qvE '^[-+]version = '; then
        git diff -- Cargo.lock >&2
        die "bumping the version changed Cargo.lock beyond $name's own entry"
    fi

    if [ -f CHANGELOG.md ]; then
        git-cliff --offline --unreleased --tag "$tag" --prepend CHANGELOG.md
    else
        git-cliff --offline --unreleased --tag "$tag" --output CHANGELOG.md
    fi

    git add Cargo.toml Cargo.lock CHANGELOG.md
    git -c commit.gpgsign=false commit --quiet -m "chore(release): $tag"
    git -c tag.gpgsign=false tag -a "$tag" -m "$tag"
    released=true
    echo "Prepared $name $tag at $(git rev-parse HEAD)" >&2
fi

git-cliff --offline --latest --strip all >"$out/release-notes.md"
git bundle create --quiet "$out/prepared.bundle" HEAD "refs/tags/$tag"
echo "$version" >"$out/version"
echo "$released" >"$out/released"
