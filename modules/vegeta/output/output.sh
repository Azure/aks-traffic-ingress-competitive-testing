#!/bin/bash

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"


function summarize() {
    cat $statefile
}

# If script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    summarize "$@"
fi