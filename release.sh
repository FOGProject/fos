#!/bin/bash

. /var/lib/buildkite-agent/github-upload.sh
[[ -z ${GITHUB_USER} || -z ${GITHUB_TOKEN} ]] && echo "Missing Github information, can't proceed." && exit 1

command -v curl
[[ $? -ne 0 ]] && echo "Package curl not installed, can't proceed." && exit 1
command -v jq
[[ $? -ne 0 ]] && echo "Package jq not installed, can't proceed." && exit 1

GITHUB_TAG=$(date +%Y%m%d)
GITHUB_NAME="Latest from $(date +%d.%m.%Y)"

curl -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases -d "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\" }" > create_release_response.json

GITHUB_RELEASE_ID=$(cat create_release_response.json | jq -r .id)

[[ -z ${GITHUB_RELEASE_ID} ]] && echo "ID not found in response, something went wrong when trying to create a release on Github." && cat create_release_response.json

buildkite-agent artifact download dist/* .
cd dist/

for i in `ls -1`
do
    echo "Trying to upload ${i}..."
    curl -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Content-Type: application/octet-stream" --data-binary "@${i}" "https://uploads.github.com/repos/FOGProject/fos/releases/${GITHUB_RELEASE_ID}/assets?name=${i}" > ${i}.uploaded
    cat ${i}.uploaded
    sleep 1
    echo ""
    echo ""
done
