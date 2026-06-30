#!/bin/bash

. /var/lib/buildkite-agent/github-upload.sh
[[ -z ${GITHUB_USER} || -z ${GITHUB_TOKEN} ]] && echo "Missing Github information, can't proceed." && exit 1

GITHUB_API="https://api.github.com/repos/FOGProject/fos"

# Authenticated call to the FOS GitHub API. Usage:
#   github_api <METHOD> <endpoint> [json-data]
# <endpoint> is appended to $GITHUB_API. Response is written to stdout; the
# caller redirects to a file or pipes to jq as needed.
github_api() {
    local method="$1" endpoint="$2" data="$3"
    if [[ -n $data ]]; then
        curl -s -X "$method" -u "${GITHUB_USER}:${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${GITHUB_API}${endpoint}" -d "$data"
    else
        curl -s -X "$method" -u "${GITHUB_USER}:${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "${GITHUB_API}${endpoint}"
    fi
}

command -v curl
[[ $? -ne 0 ]] && echo "Package curl not installed, can't proceed." && exit 1
command -v jq
[[ $? -ne 0 ]] && echo "Package jq not installed, can't proceed." && exit 1

KERNEL_VERSION=$(grep KERNEL_VERSION= build.sh | cut -d"'" -f2)
BUILDROOT_VERSION=$(grep BUILDROOT_VERSION= build.sh | cut -d"'" -f2)

if [[ -n "$1" && "$1" =~ ^[0-9]\.[0-9][0-9]*\.[0-9][0-9]*$ ]]; then
    # official release build
    GITHUB_TAG=$1
    GITHUB_NAME="FOG $1 kernels and inits"
    github_api POST /releases "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\", \"body\":\"Linux kernel ${KERNEL_VERSION}\nBuildroot ${BUILDROOT_VERSION}\" }" > response.json
elif [[ -n "$1" ]]; then
    # beta testing builds
    GITHUB_TAG="testing"
    GITHUB_NAME="Testing from $(date +%d.%m.%Y)"
    TESTING_RELEASE_ID=$(github_api GET /releases/tags/${GITHUB_TAG} | jq -r .id)
    HEAD_SHA=$(github_api GET /git/refs/heads/${1} | jq -r .object.sha)
    github_api PATCH /git/refs/tags/${GITHUB_TAG} "{ \"sha\":\"${HEAD_SHA}\" }" > tag_update_response.json
    github_api PATCH /releases/${TESTING_RELEASE_ID} "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\", \"body\":\"Linux kernel ${KERNEL_VERSION}\nBuildroot ${BUILDROOT_VERSION}\nGithub-Branch ${1}\" }" > response.json
else
    # semi-official development builds
    GITHUB_TAG=$(date +%Y%m%d)
    GITHUB_NAME="Latest from $(date +%d.%m.%Y)"
    github_api POST /releases "{ \"tag_name\":\"${GITHUB_TAG}\", \"name\":\"${GITHUB_NAME}\", \"body\":\"Linux kernel ${KERNEL_VERSION}\nBuildroot ${BUILDROOT_VERSION}\" }" > response.json
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
        ASSET_ID=$(github_api GET /releases/${GITHUB_RELEASE_ID}/assets | jq -r '.[] | "\(.id),\(.name)"' | grep ",${i}\$"| cut -f1 -d,)
        if [[ -n "${ASSET_ID}" ]]; then
            github_api DELETE /releases/assets/${ASSET_ID}
        fi
    fi
    curl -s -X POST -u ${GITHUB_USER}:${GITHUB_TOKEN} -H "Content-Type: application/octet-stream" --data-binary "@${i}" "https://uploads.github.com/repos/FOGProject/fos/releases/${GITHUB_RELEASE_ID}/assets?name=${i}" > ${i}.uploaded
    UPLOAD_STATUS=$(cat ${i}.uploaded | jq -r .state)
    [[ ${UPLOAD_STATUS} != "uploaded" ]] && echo "Failed to upload file ${i}." && cat ${i}.uploaded && exit 1
    sleep 1
done
