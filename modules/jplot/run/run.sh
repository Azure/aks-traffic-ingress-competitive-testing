#!/bin/bash

set -e

function vegeta() {
    echo "Plotting vegeta results..."
    # Code histogram keys are now exact status codes (per modules/vegeta/lib/aggregate.awk),
    # not jaggr's binned 100/200/300/400/500 families. Plot the codes that vegeta actually
    # emits in this repo's tests: 0 (transport-level failure), 200 (success), and the most
    # common controller-level error codes (502, 503).
    jplot rps+successful_count+code.hist.0+code.hist.200+code.hist.502+code.hist.503 \
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
