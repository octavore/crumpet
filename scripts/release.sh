#!/bin/sh
# Tags the current commit and pushes it, triggering a GitHub release.
# Usage: axo release <version>  (e.g. 0.2.0)
set -e

CURRENT="$(git tag --sort=-v:refname | head -n 1)"
echo "current release: ${CURRENT:-none}"

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "usage: axo release <version>  (e.g. 0.2.0)" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean, aborting" >&2
  exit 1
fi

echo "This will:"
echo "  1. tag $(git rev-parse --short HEAD) as $VERSION"
echo "  2. push main to github"
echo "  3. push tag $VERSION to github, triggering a GitHub release"
printf "Continue? [y/N] "
read -r ANSWER
case "$ANSWER" in
  y|Y|yes|YES) ;;
  *) echo "aborted" >&2; exit 1 ;;
esac

git tag "$VERSION"
git push github main
git push github "$VERSION"
