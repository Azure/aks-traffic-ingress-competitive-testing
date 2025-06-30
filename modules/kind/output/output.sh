#!/bin/bash

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function ingress_class() {
    jq -r '.ingress_class' "${statefile}" || {
        echo "Error: Could not retrieve ingress class from state file."
        exit 1
    }
}

function ingress_url() {
    jq -r '.ingress_url' "${statefile}" || {
        echo "Error: Could not retrieve ingress URL from state file."
        exit 1
    }
}

if declare -f "$1" > /dev/null
then
  # call arguments verbatim
  "$@"
else
  # Show a helpful error
  echo "'$1' is not a known function name" >&2
  exit 1
fi
