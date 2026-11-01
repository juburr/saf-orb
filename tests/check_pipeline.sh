#!/usr/bin/env bash
#
# Checks what the CI jobs' pipeline wrote to DIR (output_dir) with the real
# SAF CLI: the HDF each conversion wrote, each threshold check's verdict and
# report, the summary, and each export. test-deploy.yml and the GitHub
# Actions workflow run the same pipeline, and this checks both.
#
# Usage, from a checkout:
#   bash tests/check_pipeline.sh DIR

set -euo pipefail

DIR=${1:?Usage: $0 DIR}
FAILURES=0
check() {
    local description=$1
    shift
    if "$@"; then
        echo "ok: ${description}"
    else
        echo "FAIL: ${description}"
        FAILURES=$((FAILURES + 1))
    fi
}
# is FILE FILTER: FILE holds JSON for which FILTER is true.
is() { [[ "$(jq -c "($2) | if . then true else false end" "$1" 2> /dev/null)" == true ]]; }
controls() { is "$1" '[.profiles[].controls | length] | add > 0'; }

for name in sarif grype openscap zap ckl; do
    check "convert wrote ${name}.json, HDF with controls" controls "${DIR}/${name}.json"
done
for host in 10.0.0.1 10.0.0.2 10.0.0.3; do
    check "convert wrote one HDF file per Nessus host (${host})" controls "${DIR}/nessus-${host}.json"
done
check "convert listed the Nessus files" test "$(wc -l < "${DIR}/nessus.files")" -eq 3

check "red_hat_good meets SAF's own good thresholds" is "${DIR}/good.json" '.passed == 1 and .failed == 0'
check "with its counts" is "${DIR}/good.json" '.results[0].counts.passed.total > 200 and .results[0].counts.failed.total == 0'
check "and no_impact.total.max checked by the step" is "${DIR}/good.json" '.thresholds.no_impact.total.max == 24'
check "its run record names the verified SAF CLI" is "${DIR}/good.run-record.json" \
    '.outcome == "passed" and .tool.name == "saf" and .tool.install.verify_checksums == "strict"
     and (.tool.install.sha512 | length) == 128'
check "its JUnit has the file" grep -q '<testcase classname="good" name="red_hat_good.json' "${DIR}/junit/good.xml"
check "rhel-8_hardened meets its exact thresholds" is "${DIR}/exact.json" '.passed == 1'
check "rhel-8_hardened fails SAF's own bad thresholds" is "${DIR}/bad.json" \
    '.failed == 1 and (.results[0].message | startswith("no_impact.high.max: Threshold not met"))'

check "summary has both profiles" is "${DIR}/summary.json" \
    '[.[].profileName] | sort == ["Red Hat Enterprise Linux 7 STIG", "redhat-enterprise-linux-8-stig-baseline"]'
check "with the SAF CLI's counts for rhel-8_hardened" is "${DIR}/summary.json" \
    '.[] | select(.profileName == "redhat-enterprise-linux-8-stig-baseline")
     | .compliance == 66 and .passed.total == 227 and .failed.total == 112'
check "summary wrote Markdown and YAML too" test -s "${DIR}/summary.md" -a -s "${DIR}/summary.yml"

check "export wrote a checklist" grep -q '<CHECKLIST>' "${DIR}/red_hat_good.ckl"
check "export wrote XCCDF" grep -q '<Benchmark' "${DIR}/red_hat_good.xml"
check "export wrote CSV" test -s "${DIR}/red_hat_good.csv"
check "export wrote HTML" grep -q '<html' "${DIR}/red_hat_good.html"
check "export wrote a CAAT spreadsheet" test "$(head -c 2 "${DIR}/caat.xlsx")" = PK

check "the SAF CLI left no saf-cli.log in the working directory" test ! -e saf-cli.log

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All pipeline checks passed."
