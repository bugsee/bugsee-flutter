#!/usr/bin/env bash

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ "$1" == "" ]]; then
  echo "Usage: ./scripts/release.sh <version>"
  exit 1
fi

# Update version file
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -E -i '' "s/BUGSEE_PLUGIN_VERSION=\"[^\"]+\"/BUGSEE_PLUGIN_VERSION=\"$1\"/" ./version.txt
else
    sed -e "s/BUGSEE_PLUGIN_VERSION=\"[^\"]+\"/BUGSEE_PLUGIN_VERSION=\"$1\"/" -i ./version.txt
fi

source ./version.txt

if [[ "$1" != "$BUGSEE_PLUGIN_VERSION" ]]; then
  echo "Failed to update version file"
  exit 1
fi

# Create release commit
git add ./version.txt
git commit -m "Release: Bump version to $1"
git push origin HEAD:refs/for/$CURRENT_BRANCH

# Create release tag
git tag v$1
git push origin v$1