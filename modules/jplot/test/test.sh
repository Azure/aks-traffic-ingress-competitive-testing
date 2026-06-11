#!/bin/bash

set -e

echo "Testing JPlot module..."

echo "1. Testing JPlot installation..."
MODULE_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." ; pwd -P )
PROJECT_ROOT=$( cd "${MODULE_DIR}/../.." ; pwd -P )
chmod +x "${MODULE_DIR}/install/install.sh"
echo "Running JPlot installation..."
"${MODULE_DIR}/install/install.sh"

# Verify JPlot is installed
if ! command -v jplot &> /dev/null; then
    echo "ERROR: JPlot installation failed - jplot command not found"
    exit 1
fi

echo "2. Verifying jplot field paths match the vegeta aggregator schema..."
# Drift between modules/jplot/run/run.sh's hardcoded jplot args and the schema
# emitted by modules/vegeta/lib/aggregate.awk silently breaks the live
# dashboard. This test:
#   - generates a representative statefile.json via aggregate.awk
#   - dispatches the jplot run script with `jplot` overridden to print its args
#   - resolves each printed field path against the sample JSON with jq
# Any path that doesn't resolve (e.g. removed field, renamed key) fails CI.

AGG="${PROJECT_ROOT}/modules/vegeta/lib/aggregate.awk"
if [[ ! -f "$AGG" ]]; then
    echo "ERROR: vegeta aggregator not found at ${AGG}"
    exit 1
fi

SAMPLE_CSV=$(mktemp -t jplot-test.XXXXXX.csv)
SAMPLE_JSON=$(mktemp -t jplot-test.XXXXXX.json)
trap 'rm -f "${SAMPLE_CSV}" "${SAMPLE_JSON}"' RETURN

# One record per hundreds family in the same second-bucket so every family
# bin (0/100/200/300/400/500) has a non-zero count. This exercises every
# code.family.* path jplot might reference, not just the families that happen
# to appear in lighter tests.
#   0   transport failure                  → code.family.0   = 1
#   101 1xx (Switching Protocols)          → code.family.100 = 1
#   200 2xx (success — successful_count)   → code.family.200 = 1
#   301 3xx (redirect)                     → code.family.300 = 1
#   404 4xx (client error)                 → code.family.400 = 1
#   503 5xx (server error)                 → code.family.500 = 1
cat > "${SAMPLE_CSV}" <<'EOF'
1700000001000000,101,5000000,0,13,
1700000002000000,200,5000000,0,13,
1700000003000000,301,5000000,0,13,
1700000004000000,404,5000000,0,13,
1700000005000000,503,5000000,0,13,
1700000006000000,0,30000000000,0,0,
EOF
gawk -f "${AGG}" "${SAMPLE_CSV}" > "${SAMPLE_JSON}"
SAMPLE_LINE=$(head -n1 "${SAMPLE_JSON}")
if [[ -z "${SAMPLE_LINE}" ]]; then
    echo "ERROR: aggregate.awk produced no sample output"
    exit 1
fi

# Sanity: confirm every family bin is populated as designed. If a future
# aggregator change accidentally collapses some families, this catches it
# before the schema-resolution loop does.
echo "${SAMPLE_LINE}" | jq -e \
    '.code.family == {"0":1,"100":1,"200":1,"300":1,"400":1,"500":1}' > /dev/null \
    || { echo "ERROR: sample code.family did not populate every bin"; echo "${SAMPLE_LINE}"; exit 1; }
echo "  ✓ sample populates every family bin (0/100/200/300/400/500) with count 1"

# Capture jplot's argument list by overriding it in a child bash invocation.
# `source` with positional args dispatches run.sh's vegeta function, which
# calls our stub `jplot` instead of the real binary.
JPLOT_ARGS=$(bash <<EOF
jplot() { printf '%s\n' "\$@"; }
source "${MODULE_DIR}/run/run.sh" vegeta
EOF
)

# Translate dotted paths (rps, code.family.0, latency.p99) into jq selectors.
# Numeric path segments need bracket notation: code.family.0 → .code.family["0"].
to_jq_path() {
    gawk -F. '
    {
        out = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/) {
                out = out "[\"" $i "\"]"
            } else {
                if (i > 1) out = out "."
                out = out $i
            }
        }
        if (substr(out, 1, 1) != "[") out = "." out
        else out = "" out  # rare: leading numeric segment, leave bracket form
        print out
    }'
}

MISSING_PATHS=()
PANEL_COUNT=0
PATH_COUNT=0
while IFS= read -r panel; do
    [[ -z "$panel" ]] && continue
    [[ "$panel" == "Plotting vegeta results..." ]] && continue
    PANEL_COUNT=$((PANEL_COUNT + 1))
    IFS='+' read -ra FIELDS <<< "$panel"
    for field in "${FIELDS[@]}"; do
        PATH_COUNT=$((PATH_COUNT + 1))
        jq_path=$(printf '%s' "$field" | to_jq_path)
        if ! echo "$SAMPLE_LINE" | jq -e "${jq_path}" > /dev/null 2>&1; then
            MISSING_PATHS+=("$field   (jq: ${jq_path})")
        fi
    done
done <<< "${JPLOT_ARGS}"

if [[ "${PANEL_COUNT}" -eq 0 ]]; then
    echo "ERROR: failed to extract any jplot panels from ${MODULE_DIR}/run/run.sh"
    echo "Captured output was:"
    echo "${JPLOT_ARGS}"
    exit 1
fi

if [[ ${#MISSING_PATHS[@]} -gt 0 ]]; then
    echo "ERROR: jplot is configured to plot fields that don't exist in aggregate.awk's output:"
    printf '  - %s\n' "${MISSING_PATHS[@]}"
    echo "Sample JSON line:"
    echo "${SAMPLE_LINE}"
    exit 1
fi
echo "  ✓ all ${PATH_COUNT} jplot field paths across ${PANEL_COUNT} panels resolve in the aggregator's JSON"

echo "🎉 All JPlot module tests passed!"