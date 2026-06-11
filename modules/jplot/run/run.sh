#!/bin/bash

set -e

function vegeta() {
    echo "Plotting vegeta results..."
    # code.family bins exact codes into hundreds families (0/100/200/300/400/500)
    # and always emits all six keys, so jplot has a stable schema regardless of
    # which exact codes a particular controller returns. response_rate and
    # success_rate are layered: response_rate = responded_count / rps,
    # success_rate = successful_count (2xx) / responded_count.
    jplot rps+responded_count+successful_count \
      response_rate+success_rate \
      code.family.0+code.family.100+code.family.200+code.family.300+code.family.400+code.family.500 \
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
