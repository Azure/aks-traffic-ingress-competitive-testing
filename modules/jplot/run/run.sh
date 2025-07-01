#!/bin/bash

set -e

function vegeta() {
    echo "Plotting vegeta results..."
    jplot rps+code.hist.100+code.hist.200+code.hist.300+code.hist.400+code.hist.500 \
      latency.p99+latency.p50+latency.p25 \
      bytes_in.sum+bytes_out.sum
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
