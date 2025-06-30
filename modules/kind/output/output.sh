#!/bin/bash

set -e

filepath=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
statefile="${filepath}/../statefile.json"

function output_ingress_class() {
    jq -r '.ingress_class' "${statefile}" || {
        echo "Error: Could not retrieve ingress class from state file."
        exit 1
    }
}

function output_ingress_url() {
    jq -r '.ingress_url' "${statefile}" || {
        echo "Error: Could not retrieve ingress URL from state file."
        exit 1
    }
}
