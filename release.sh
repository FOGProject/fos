#!/bin/bash

buildkite-agent artifact download dist/* .
ls -alR dist/
ls -al /var/lib/buildkite-agent/
ls -al /var/lib/buildkite-agent/builds/
ls -al /var/lib/buildkite-agent/builds/Tollana-1/
