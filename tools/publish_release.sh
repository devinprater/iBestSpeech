#!/usr/bin/env bash
# Publish (or verify) a tagged release and verify the actual downloadable bytes.
# GitHub's /releases/tags/TAG and gh release view/download may return a stale
# embedded assets:[] even while /releases/ID/assets and the public download work.
# Never delete/recreate a release on the strength of the tag lookup.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo 'usage: publish_release.sh TAG IPA [NOTES_FILE] (omit notes to verify only)' >&2
    exit 2
fi
TAG=$1
IPA=$2
NOTES=${3:-}
[[ -f "$IPA" ]] || { echo "missing IPA: $IPA" >&2; exit 1; }
if [[ -n "$NOTES" ]]; then
    [[ -f "$NOTES" ]] || { echo "missing release notes: $NOTES" >&2; exit 1; }
fi
REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}
if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi
NAME=$(basename "$IPA")
EXPECTED_NAME="iBestSpeech-${TAG#v}-sideload.ipa"
[[ "$NAME" == "$EXPECTED_NAME" ]] || {
    echo "IPA name $NAME does not match release $TAG ($EXPECTED_NAME)" >&2
    exit 1
}

# Tag lookup is used ONLY to resolve the numeric release ID. Its embedded
# assets field is unreliable; never make publish/delete decisions from it.
if RELEASE_ID=$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id 2>/dev/null); then
    :
else
    RELEASE_ID=""
fi
if [[ -z "$RELEASE_ID" ]]; then
    if [[ -z "$NOTES" ]]; then
        echo "release $TAG does not exist (verify-only mode)" >&2; exit 1
    fi
    gh release create "$TAG" "$IPA" -R "$REPO" \
        --title "iBestSpeech ${TAG#v}" --notes-file "$NOTES" --verify-tag
    RELEASE_ID=$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id)
fi

# A release asset is an independent resource; query its canonical list route.
ASSET=$(gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" \
    --jq ".[] | select(.name == \"$NAME\") | .id")
if [[ -z "$ASSET" ]]; then
    if [[ -z "$NOTES" ]]; then
        echo "release $TAG has no $NAME (verify-only mode)" >&2; exit 1
    fi
    gh release upload "$TAG" "$IPA" -R "$REPO"
    ASSET=$(gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" \
        --jq ".[] | select(.name == \"$NAME\") | .id")
fi
[[ -n "$ASSET" ]] || { echo "release $TAG has no $NAME after upload" >&2; exit 1; }

META="repos/$REPO/releases/assets/$ASSET"
STATE=$(gh api "$META" --jq .state)
SIZE=$(gh api "$META" --jq .size)
URL=$(gh api "$META" --jq .browser_download_url)
[[ "$STATE" == uploaded ]] || { echo "release asset $ASSET is $STATE" >&2; exit 1; }
EXPECTED_SIZE=$(wc -c < "$IPA" | tr -d ' ')
[[ "$SIZE" == "$EXPECTED_SIZE" ]] || {
    echo "release asset $ASSET size $SIZE != local $EXPECTED_SIZE" >&2; exit 1
}

# The browser URL works even when gh release download falsely says no assets.
# Download the exact asset and compare bytes, not merely GitHub's response code.
TMPBASE=${RUNNER_TEMP:-${TMPDIR:-$HOME}}
VERIFY_DIR=$(mktemp -d "$TMPBASE/ibestspeech-release.XXXXXXXX")
trap 'rm -rf "$VERIFY_DIR"' EXIT
curl --fail --location --silent --show-error --retry 3 \
    --output "$VERIFY_DIR/$NAME" "$URL"
LOCAL=$(shasum -a 256 "$IPA" | cut -d' ' -f1)
REMOTE=$(shasum -a 256 "$VERIFY_DIR/$NAME" | cut -d' ' -f1)
[[ "$LOCAL" == "$REMOTE" ]] || {
    echo "release asset $ASSET does not match built IPA ($LOCAL != $REMOTE)" >&2
    exit 1
}
printf 'verified %s release=%s asset=%s size=%s sha256=%s\n' \
    "$TAG" "$RELEASE_ID" "$ASSET" "$SIZE" "$LOCAL"
