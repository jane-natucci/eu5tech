#!/usr/bin/env bash
# Uploads the site to S3, where CloudFront serves it as eu5tech.jane.berlin.
#
#   ./deploy.sh              full deploy: page, our own files and the game
#                            data in eu5/ (run extract.rb first; needs a
#                            machine with Europa Universalis V installed
#                            and a melted 1337 save)
#   ./deploy.sh --code-only  page and our own files only, reusing the game
#                            data already on S3 -- what CI runs on every push
#                            to main. The very first deploy has to be a full
#                            one, since CI can't generate the data.
#
# Every /eu5/ URL carries ?v=<version>, which CloudFront caches /eu5/* on
# for a year. The version hashes data.json plus our own tracked files in
# eu5/ (e.g. favicon.svg), so a new extraction or a change to any of those
# files busts the cache. index.html is sent with no-cache, so a deploy shows
# up immediately.
set -euo pipefail
cd "$(dirname "$0")"

bucket="${EU5_BUCKET:-eu5tech.jane.berlin}"
# Locally, use the named profile; in CI, credentials come from the OIDC role.
[ -n "${CI:-}" ] || export AWS_PROFILE="${AWS_PROFILE:-personal}"

md5() { if command -v md5sum >/dev/null; then md5sum | cut -d' ' -f1; else command md5 -q; fi; }
tracked=$(git ls-files eu5)   # our own files in eu5/ (the rest is generated)
tmp="$(mktemp -d)"

if [ "${1:-}" = "--code-only" ]; then
  aws s3 cp "s3://${bucket}/eu5/data.json" "$tmp/data.json" --only-show-errors || {
    echo "No eu5/data.json on S3 yet. The first deploy must be a full one:" >&2
    echo "run 'ruby extract.rb && ./deploy.sh' on a machine with Europa Universalis V installed." >&2
    exit 1
  }
  data="$tmp/data.json"
else
  [ -f eu5/data.json ] || { echo "No eu5/data.json -- run: ruby extract.rb" >&2; exit 1; }
  data="eu5/data.json"
fi

version="$(cat "$data" $tracked | md5)"
version="${version:0:10}"
# The header's "Build <sha>" link points at the deployed commit on GitHub.
# A local deploy with uncommitted changes to the page or our files says so.
sha="$(git rev-parse HEAD)"
label="${sha:0:7}"
[ -z "$(git status --porcelain -- index.html $tracked)" ] || label="${label}-dirty"
sed -e "s/__DATA_VERSION__/${version}/g" -e "s/__BUILD_SHA__/${sha}/g" -e "s/__BUILD_LABEL__/${label}/g" \
  index.html > "$tmp/index.html"

# Assets first, page last, so a new page never points at files not yet there.
if [ "${1:-}" = "--code-only" ]; then
  for f in $tracked; do
    aws s3 cp "$f" "s3://${bucket}/${f}" --only-show-errors --cache-control "public, max-age=31536000"
  done
else
  aws s3 sync eu5/ "s3://${bucket}/eu5/" --delete --exclude ".DS_Store" --exclude "links.json" \
    --cache-control "public, max-age=31536000"
  # links.json (country name -> tag) is read by other apps that link here; at the root, not under the
  # year-long-cached /eu5/, so a change shows up within the hour.
  aws s3 cp eu5/links.json "s3://${bucket}/links.json" --only-show-errors \
    --cache-control "public, max-age=3600" --content-type "application/json"
fi
aws s3 cp "$tmp/index.html" "s3://${bucket}/index.html" --only-show-errors \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8"

echo "Deployed version ${version} to s3://${bucket}${1:+ ($1)}"
