#!/usr/bin/env bash
#
# Downloads the SAF CLI's own sample data, which the CI jobs run the orb on,
# from the mitre/saf repository at the commit SAF CLI 1.7.0 was built from:
# results of the tools convert reads, HDF results, and threshold templates
# the SAF CLI's own tests use with them.
#
# Usage, from a checkout:
#   bash tests/fetch_samples.sh DIR

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 DIR" >&2
    exit 2
fi
DIR=$1
COMMIT=377c0f566d4e02ba756d214d47c2682cd92823c7
BASE="https://raw.githubusercontent.com/mitre/saf/${COMMIT}/test/sample_data"
FILES=(
    sarif/sample_input_report/sarif_input.sarif
    anchoregrype/sample_input_report/anchore_grype.json
    xccdf_results/sample_input_report/xccdf-results-openscap-rhel8.xml
    nessus/sample_input_report/sample.nessus
    zap/sample_input_report/webgoat.json
    checklist/sample_input_report/small_ckl_overrides.ckl
    HDF/input/red_hat_good.json
    HDF/input/rhel-8_hardened.json
    thresholds/red_hat_good.counts.good.yml
    thresholds/rhel-8_hardened.counts.good.exact.yml
    thresholds/rhel-8_hardened.counts.bad.noimpactHigh.yml
)
mkdir -p "${DIR}"
for file in "${FILES[@]}"; do
    curl -sS --fail --location --proto '=https' --retry 5 -o "${DIR}/${file##*/}" "${BASE}/${file}"
    echo "Downloaded ${file##*/}"
done
