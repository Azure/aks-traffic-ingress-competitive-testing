#!/bin/bash

set -e

function plot_vegeta() {
    local input_file="$1"
    local output_file="$2"

    if [[ ! -f "$input_file" ]]; then
        echo "Input file not found: $input_file"
        exit 1
    fi

    echo "Plotting vegeta results from $input_file to $output_file..."
    jplot -f "$input_file" -o "$output_file"
}
