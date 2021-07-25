#!/bin/bash

. /var/lib/buildkite-agent/github-upload.sh
[[ -z ${GITHUB_USER} || -z ${GITHUB_TOKEN} ]] && echo "Missing Github information, can't proceed" && exit 1

command -v jqa
[[ $? -eq 0 ]] || echo "Package jq not installed, can't proceed" && exit 1

GITHUB_TAG=$(date +%Y%m%d)
GITHUB_NAME="Latest from $(date +%d.%m.%Y)"

echo "Today is ${today}"

#buildkite-agent artifact download dist/* .
#cd dist/

#curl -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases -d "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\" }"
