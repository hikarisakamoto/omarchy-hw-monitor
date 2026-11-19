#!/bin/bash
# Cut a release: date the CHANGELOG's Unreleased notes as the new version, bump
# manifest.json to match, run the checks, then commit and tag. Nothing is pushed.
#
#   scripts/release.sh 1.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "release: $*" >&2
  exit 1
}

version=${1:-}
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "usage: scripts/release.sh X.Y.Z"
current=$(jq -r .version manifest.json)
[[ $version != "$current" && $(printf '%s\n' "$current" "$version" | sort -V | tail -n 1) == "$version" ]] ||
  fail "$version is not newer than $current"
[[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then fail "tag v$version already exists"; fi

# The notes are the non-blank lines between "## Unreleased" and the next "## ".
notes=$(awk '/^## / { if (seen) exit; if ($0 == "## Unreleased") { seen = 1; next } } seen && NF' CHANGELOG.md)
[[ -n $notes ]] || fail "CHANGELOG.md has nothing under ## Unreleased"

# Edit the one line in each file with sed: jq would rewrite the manifest's
# \uXXXX glyph escapes as raw UTF-8.
restore() { git checkout -- manifest.json CHANGELOG.md; }
sed -i "s/^## Unreleased\$/## Unreleased\n\n## $version — $(date +%F)/" CHANGELOG.md
sed -i "s/^  \"version\": \"${current//./\\.}\",\$/  \"version\": \"$version\",/" manifest.json
[[ $(git diff --numstat -- manifest.json) == $'1\t1\tmanifest.json' ]] ||
  { restore; fail "could not change exactly the version line of manifest.json"; }
scripts/check.sh >/dev/null || { restore; fail "scripts/check.sh failed; nothing was committed"; }

# --cleanup=whitespace keeps the notes' "### Added/Changed/Fixed" headings:
# git tag (and git commit under commit.cleanup=strip) would drop every line
# that starts with "#".
git commit -q --cleanup=whitespace -m "chore: release v$version" -m "$notes" -- manifest.json CHANGELOG.md
git tag -a --cleanup=whitespace "v$version" -m "v$version" -m "$notes"
echo "Released v$version. Push with: git push && git push origin v$version"
