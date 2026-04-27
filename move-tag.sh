#!/bin/bash
# Move git tag v2.8.0-monstermq to the latest commit

set -e

TAG="v2.8.0-monstermq"
CURRENT_COMMIT=$(git rev-parse HEAD)

echo "Moving tag $TAG to $CURRENT_COMMIT..."

# Delete the old tag
git tag -d "$TAG"

# Create the tag at the current commit
git tag "$TAG"

echo "Tag $TAG now points to:"
git show "$TAG" --oneline | head -1
