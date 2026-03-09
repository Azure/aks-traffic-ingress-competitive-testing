#!/bin/bash

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function cluster_name() {
    jq -r '.cluster_name' "${statefile}" || {
        echo "Error: Could not retrieve cluster name from state file."
        exit 1
    }
}

function host_port() {
    jq -r '.host_port' "${statefile}" || {
        echo "Error: Could not retrieve host port from state file."
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
