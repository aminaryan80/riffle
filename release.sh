#!/bin/bash
# Cuts a new Riffle release: bumps the version, builds the signed .zip, tags the
# commit, and publishes a GitHub release with the .zip attached (so the in-app
# updater can auto-install it). The new version bumps the minor component and
# resets the patch to 0, e.g. 1.0.1 -> 1.1.0.
set -euo pipefail
cd "$(dirname "$0")"

PLIST="Resources/Info.plist"
REPO="aminaryan80/riffle"

command -v gh >/dev/null 2>&1 || {
  echo "error: GitHub CLI (gh) is required. Install with 'brew install gh' and run 'gh auth login'." >&2
  exit 1
}

# An invalid/stale GITHUB_TOKEN in the environment overrides gh's keyring login
# and makes `gh release create` fail after the tag is already pushed.
unset GITHUB_TOKEN

if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "error: GitHub CLI is not authenticated. Run:" >&2
  echo "  gh auth refresh -h github.com -s workflow" >&2
  exit 1
fi

# Refuse to release with a dirty tree — the version bump must be the only change.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty. Commit or stash changes before releasing." >&2
  exit 1
fi

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${PLIST}")"
IFS='.' read -r MAJOR MINOR _ <<< "${CURRENT}"
NEW="${MAJOR}.$((MINOR + 1)).0"
TAG="v${NEW}"
echo "==> Bumping ${CURRENT} -> ${NEW}"

/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${NEW}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${NEW}" "${PLIST}"

./build.sh
ZIP="dist/Riffle-${NEW}.zip"

echo "==> Committing and tagging ${TAG}…"
git add "${PLIST}"
git commit -m "Release ${NEW}"
git tag "${TAG}"

echo "==> Pushing…"
git push origin HEAD
git push origin "${TAG}"

echo "==> Creating GitHub release ${TAG}…"
if ! gh release create "${TAG}" "${ZIP}" \
  --repo "${REPO}" \
  --title "${NEW}" \
  --generate-notes; then
  echo "error: failed to create release. If gh mentioned a missing \"workflow\" scope, run:" >&2
  echo "  unset GITHUB_TOKEN" >&2
  echo "  gh auth refresh -h github.com -s workflow" >&2
  echo "Then retry just the release step:" >&2
  echo "  unset GITHUB_TOKEN && gh release create ${TAG} ${ZIP} --repo ${REPO} --title ${NEW} --generate-notes" >&2
  exit 1
fi

# The release now lives on GitHub, so the local build artifacts are redundant.
echo "==> Cleaning up dist…"
rm -rf dist

echo "==> Released ${NEW}"
