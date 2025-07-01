#!/bin/bash

# Script to install jplot - A command-line tool for plotting JSON and CSV data
# https://github.com/rs/jplot

set -e

JPLOT_VERSION="v1.1.6"

echo "Installing jplot ${JPLOT_VERSION}..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "ERROR: Go is required to install jplot but is not installed."
    echo "Please install Go from https://golang.org/dl/ before running this script."
    exit 1
fi

echo "Go found: $(go version)"

# Install jplot using go install
echo "Installing jplot ${JPLOT_VERSION} using go install..."
go install github.com/rs/jplot@${JPLOT_VERSION}

# Check if GOPATH/bin or GOBIN is in PATH
GOBIN_PATH=$(go env GOPATH)/bin
if [[ ":$PATH:" != *":$GOBIN_PATH:"* ]]; then
    echo "WARNING: $GOBIN_PATH is not in your PATH."
    echo "Add the following line to your shell profile (.bashrc, .zshrc, etc.):"
    echo "export PATH=\$PATH:$GOBIN_PATH"
    echo ""
fi

echo "Verifying jplot installation..."
if command -v jplot &> /dev/null; then
    echo "jplot installation complete!"
else
    echo "jplot installed but not found in PATH. You may need to add $(go env GOPATH)/bin to your PATH."
    echo "jplot is installed at: $GOBIN_PATH/jplot"
fi