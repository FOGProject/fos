#!/bin/bash

. /var/lib/buildkite-agent/github-upload.sh
[[ -z ${GITHUB_USER} || -z ${GITHUB_TOKEN} ]] && echo "Missing Github information, can't proceed." && exit 1

command -v curl
[[ $? -ne 0 ]] && echo "Package curl not installed, can't proceed." && exit 1
command -v jq
[[ $? -ne 0 ]] && echo "Package jq not installed, can't proceed." && exit 1

KERNEL_VERSION=$(grep KERNEL_VERSION= build.sh | cut -d"'" -f2)
BUILDROOT_VERSION=$(grep BUILDROOT_VERSION= build.sh | cut -d"'" -f2)

if [[ -n "$1" ]]; then
    GITHUB_TAG="testing"
    GITHUB_NAME="Testing from $(date +%d.%m.%Y)"
    TESTING_RELEASE_ID=$(curl -s -X GET -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases/tags/${GITHUB_TAG} | jq -r .id)
    HEAD_SHA=$(curl -s -X GET -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/git/refs/heads/${1} | jq -r .object.sha)
    curl -s -X PATCH -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/git/refs/tags/${GITHUB_TAG} -d "{ \"sha\":\"${HEAD_SHA}\" }" > tag_update_response.json
    curl -s -X PATCH -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases/${TESTING_RELEASE_ID} -d "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\", \"body\":\"Linux kernel ${KERNEL_VERSION}\nBuildroot ${BUILDROOT_VERSION}\nGithub-Branch ${1}\" }" > response.json
else
    GITHUB_TAG=$(date +%Y%m%d)
    GITHUB_NAME="Latest from $(date +%d.%m.%Y)"
    curl -s -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases -d "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\", \"body\":\"Linux kernel ${KERNEL_VERSION}\nBuildroot ${BUILDROOT_VERSION}\" }" > response.json
fi


GITHUB_RELEASE_ID=$(cat response.json | jq -r .id)

[[ -z ${GITHUB_RELEASE_ID} || ${GITHUB_RELEASE_ID} == "null" ]] && echo "ID not found in response, something went wrong when trying to create or update the release on Github." && cat response.json && exit 1

echo "Release created/updated on Github, tagged ${GITHUB_TAG}, id ${GITHUB_RELEASE_ID}."

buildkite-agent artifact download 'dist/*' .
cd dist/

for i in `ls -1`
do
    if [[ ${i} =~ "sha256" ]]
    then
        sha256sum -c ${i}
        [[ $? -ne 0 ]] && echo "Checkum check failed on ${i}." && exit 1
    fi
    echo "Uploading ${i}..."
    if [[ -n "$1" ]]; then
        ASSET_ID=$(curl -s -X GET -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases/${GITHUB_RELEASE_ID}/assets | jq -r '.[] | "\(.id),\(.name)"' | grep ",${i}\$"| cut -f1 -d,)
        if [[ -n "${ASSET_ID}" ]]; then
            curl -s -X DELETE -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/FOGProject/fos/releases/assets/${ASSET_ID}
        fi
    fi
    curl -s -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Content-Type: application/octet-stream" --data-binary "@${i}" "https://uploads.github.com/repos/FOGProject/fos/releases/${GITHUB_RELEASE_ID}/assets?name=${i}" > ${i}.uploaded
    UPLOAD_STATUS=$(cat ${i}.uploaded | jq -r .state)
    [[ ${UPLOAD_STATUS} != "uploaded" ]] && echo "Failed to upload file ${i}." && cat ${i}.uploaded && exit 1
    sleep 1
done
