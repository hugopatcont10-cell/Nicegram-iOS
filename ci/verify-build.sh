#!/bin/bash
if pgrep -x Xcode >/dev/null; then
  echo "ERROR: Xcode is running. It shares this build's global module cache;"
  echo "running both wedges swift-frontend at 0% CPU and never finishes."
  echo "Quit Xcode, then re-run."
  exit 1
fi
./bootstrap-submodules.sh || exit 1
. ./_env.sh
fastlane compile_check
