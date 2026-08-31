#!/bin/bash
./bootstrap-submodules.sh || exit 1
. ./_env.sh
fastlane generate_project
