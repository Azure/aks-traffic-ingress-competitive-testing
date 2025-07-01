#!/bin/bash

set -e

echo "Testing JPlot module..."

echo "1. Testing JPlot installation..."
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
chmod +x "${MODULE_DIR}/install/install.sh"
echo "Running JPlot installation..."
"${MODULE_DIR}/install/install.sh" 

# Verify JPlot is installed
if ! command -v jplot &> /dev/null; then
    echo "ERROR: JPlot installation failed - jplot command not found"
    exit 1
fi 

echo "🎉 All JPlot module tests passed!"