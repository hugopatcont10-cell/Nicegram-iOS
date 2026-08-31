#!/bin/bash
if [ "$1" = "" ] || [ "$2" != "" ]
then
  echo "You must pass one argument reflecting the version and build number"
  exit 1
fi

. ./_env.sh

. ./push-to-github-repo.sh beta "$1"
