#!/usr/bin/env bash
#
# Tests the command scripts offline, run by tests/run_command.sh with their
# parameters' defaults from the commands' YAML, against a stand-in saf that
# records every call (arguments, working directory, SAF_SKIP_NEW_VERSION_CHECK)
# and answers as the SAF CLI does, including its failures that exit 0 with
# a warning, and a stand-in Heimdall (tests/fake_heimdall.py):
#
#   - convert: the converter's arguments, absolute paths, the SAF CLI run in
#     a directory of its own, one file, several (per host, or a directory),
#     what an earlier run left, each way a converter fails, the exported
#     paths, and every input check failing before saf runs
#   - threshold: the template read and handed over as one nested document
#     (dotted and nested keys, min and max together, control lists), every
#     key the SAF CLI would skip refused, verdicts per file, report_only, a
#     file the SAF CLI can't check, the reports, JUnit and run records
#   - summary: the formats, the log, GitHub's job summary
#   - export: each format's output and name, its options, a failed export
#   - upload_heimdall: the request (key, file, fields), the evaluations'
#     URLs, a server without API keys, a wrong key, a failed upload, and the
#     key never shown
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it. A stand-in circleci CLI expands $ORB_TEST_VAR. Needs jq,
# curl and python3 (for the stand-in Heimdall), and Python's jsonschema to
# check the run records.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done

WORK=$(mktemp -d)
SERVER_PID=""
cleanup() {
    if [[ -n "${SERVER_PID}" ]]; then
        kill "${SERVER_PID}" 2> /dev/null || true
        wait "${SERVER_PID}" 2> /dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT
STUB="${WORK}/stub"
HOME_DIR="${WORK}/home"
JOB="${WORK}/job"
OUT="${WORK}/reports"
mkdir -p "${WORK}/bin" "${STUB}/calls" "${HOME_DIR}" "${JOB}"

# Like `circleci env subst`, expands $NAME and ${NAME} references, from stdin.
cat > "${WORK}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" != "env subst" ]]; then
    echo "circleci stub: expected 'env subst' with the value on stdin, got: $*" >&2
    exit 1
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF

# The stand-in saf. Settings:
#   STUB_CONVERT  for <tool>2hdf: ok (one HDF file at -o), multi (two, named
#                 after -o, as nessus2hdf does for two hosts), dir (two in
#                 the directory -o, as prowler2hdf does), warn (oclif's
#                 warning, exit 0, nothing written), none (nothing written),
#                 bad (JSON that isn't HDF), exit (exit 2)
#   STUB_EXPORT   for hdf2<format>: ok, warn, bad or none
#   STUB_SUMMARY  for view summary: ok or fail (exit 1)
# validate threshold answers by each HDF file's passthrough.stub: "fail"
# fails a threshold (exit 1), "error" warns as the SAF CLI does when it
# can't read something (exit 0), anything else passes.
cat > "${WORK}/bin/saf" << 'EOF'
#!/usr/bin/env bash
set +o errexit +o nounset +o pipefail +o xtrace
calls="${STUB_DIR}/calls"
if [[ "$1" == --version ]]; then
    echo "@mitre/saf/${STUB_VERSION:-1.7.0} linux-x64 node-v22.23.2"
    exit 0
fi
n=$(($(find "${calls}" -name '*.args' | wc -l) + 1))
printf '%s\n' "$@" > "${calls}/${n}.args"
printf 'cwd=%s\nskip=%s\n' "${PWD}" "${SAF_SKIP_NEW_VERSION_CHECK:-}" > "${calls}/${n}.meta"
# The SAF CLI's logger writes saf-cli.log in its working directory.
echo "info: started" >> saf-cli.log
args=("$@")
inputs=()
out=""
i=2
while ((i < ${#args[@]})); do
    case "${args[i]}" in
        -i)
            i=$((i + 1))
            while ((i < ${#args[@]})) && [[ "${args[i]}" != -* ]]; do
                inputs+=("${args[i]}")
                i=$((i + 1))
            done
            continue
            ;;
        -o) out=${args[i + 1]} ;;
        -T) cp "${args[i + 1]}" "${calls}/${n}.template" ;;
    esac
    i=$((i + 1))
done
hdf() {
    jq -n --arg p "$2" '{platform: {name: "Heimdall Tools", release: "2.12"}, version: "2.12", statistics: {},
        profiles: [{name: $p, controls: [{id: "C-1", impact: 0.7, results: [{status: "failed"}]}]}]}' > "$1"
}
case "$1 $2" in
    "convert "*2hdf)
        case "${STUB_CONVERT:-ok}" in
            ok) hdf "${out}" converted ;;
            multi)
                hdf "${out%.json}-host-a.json" host-a
                hdf "${out%.json}-host b.json" host-b
                ;;
            dir)
                mkdir -p "${out}"
                hdf "${out}/one.json" one
                hdf "${out}/two.json" two
                ;;
            warn)
                echo " ›   Error: Unable to process input file" >&2
                echo " ›         Detected input type: unknown or none" >&2
                ;;
            none) ;;
            bad) echo '{"not": "hdf"}' > "${out}" ;;
            exit)
                echo " ›   Error: Nonexistent flag: --bogus" >&2
                exit 2
                ;;
        esac
        ;;
    "convert hdf2"*)
        case "${STUB_EXPORT:-ok}" in
            ok)
                case "$2" in
                    hdf2ckl) printf '<?xml version="1.0"?>\n<CHECKLIST>\n<ASSET></ASSET>\n</CHECKLIST>\n' > "${out}" ;;
                    hdf2xccdf) printf '<Benchmark xmlns="http://checklists.nist.gov/xccdf/1.2">\n</Benchmark>\n' > "${out}" ;;
                    hdf2csv) printf 'Results Set,Status,ID\nx,Failed,C-1\n' > "${out}" ;;
                    hdf2html) printf '<!DOCTYPE html>\n<html><body>%s</body></html>\n' "${#inputs[@]}" > "${out}" ;;
                    hdf2caat) printf 'PK\003\004xlsx' > "${out}" ;;
                esac
                ;;
            warn) echo " ›   Warning: something went wrong" >&2 ;;
            bad) echo "not it" > "${out}" ;;
            none) ;;
        esac
        ;;
    "validate threshold")
        case "$(jq -r '.passthrough.stub // ""' "${inputs[0]}")" in
            fail)
                echo "Error: failed.critical.max: Threshold not met. Number of received total failed controls (1) is greater than your set threshold for the number of failed controls (0)" >&2
                exit 1
                ;;
            error) echo " ›   Warning: ENOENT: no such file or directory" >&2 ;;
            *) echo "All validation tests passed" ;;
        esac
        ;;
    "view summary")
        if [[ "${STUB_SUMMARY:-ok}" == fail ]]; then
            echo "error: Error occurred: Unexpected token" >&2
            exit 1
        fi
        format=yaml
        for ((j = 0; j < ${#args[@]}; j++)); do
            [[ "${args[j]}" == -f ]] && format=${args[j + 1]}
        done
        case "${format}" in
            json)
                for f in "${inputs[@]}"; do jq -c '.profiles[0].name' "${f}"; done | jq -s '
                    def c($n): {critical: 0, high: $n, medium: 0, low: 0, total: $n};
                    unique | map({profileName: ., resultSets: ["x.json"], compliance: 50,
                        passed: c(1), failed: c(1), skipped: c(0), error: c(0),
                        no_impact: {critical: 0, high: 0, medium: 0, low: 0, none: 0, total: 0}})' > "${out}"
                ;;
            markdown) printf '| Compliance: 50<br>:test_tube: | Passed<br>:white_check_mark: |\n| Total | 1 |\n' > "${out}" ;;
            yaml) printf -- '- profileName: converted\n  compliance: 50\n' > "${out}" ;;
        esac
        ;;
    *)
        echo " ›   Error: command $1:$2 not found" >&2
        exit 2
        ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/"*

# hdf FILE PROFILE [STUB]: writes an HDF file whose first profile is PROFILE,
# which the stand-in saf's validate threshold answers by STUB.
hdf() {
    jq -n --arg p "$2" --arg s "${3:-}" '{platform: {name: "Heimdall Tools", release: "2.12"}, version: "2.12",
        statistics: {}, passthrough: {stub: $s},
        profiles: [{name: $p, controls: [{id: "C-1", impact: 0.7, results: [{status: "failed"}]}]}]}' > "$1"
}
mkdir -p "${JOB}/hdf"
hdf "${JOB}/hdf/good.json" good
hdf "${JOB}/hdf/bad.json" bad fail
hdf "${JOB}/hdf/broken.json" broken error
echo '{"results": []}' > "${JOB}/hdf/not-hdf.json"
echo '{"version": "2.1.0", "runs": []}' > "${JOB}/results.sarif"
echo '{}' > "${JOB}/standards.json"

FAILURES=0
RC=0
OUTPUT=""
COMMAND=""

# run COMMAND [NAME=VALUE ...] [-- VAR=value ...]: runs COMMAND's script
# through tests/run_command.sh in the job directory, with output_dir in OUT,
# the parameters given and the environment settings after --. Recorded
# calls and BASH_ENV start empty, and every run record is kept to check
# against the schema at the end.
RECORDS=0
mkdir -p "${WORK}/records"
run() {
    local params=() envs=() record
    COMMAND=$1
    shift
    while [[ $# -gt 0 && "$1" != -- ]]; do
        params+=("$1")
        shift
    done
    if [[ $# -gt 0 ]]; then
        shift
        envs=("$@")
    fi
    rm -rf "${STUB}/calls"
    mkdir -p "${STUB}/calls"
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${JOB}" && env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u SAF_HDF_FILES HOME="${HOME_DIR}" \
        PATH="${WORK}/bin:${PATH}" BASH_ENV="${WORK}/bash_env" STUB_DIR="${STUB}" ${envs[@]+"${envs[@]}"} \
        bash "${ROOT}/tests/run_command.sh" "${COMMAND}" "output_dir=${OUT}" ${params[@]+"${params[@]}"} 2>&1)
    RC=$?
    for record in "${OUT}"/*.run-record.json; do
        [[ -f "${record}" ]] || continue
        RECORDS=$((RECORDS + 1))
        cp "${record}" "${WORK}/records/${RECORDS}.json"
    done
}

check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        while IFS= read -r line; do
            printf '    | %s\n' "${line}"
        done <<< "${OUTPUT}"
        for call in "${STUB}/calls/"*.args; do
            [[ -f "${call}" ]] || continue
            printf '    saf call %s: %s\n' "$(basename "${call}" .args)" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
# script_said TEXT: the script printed TEXT, not counting the line in which
# run_command.sh shows the parameters.
script_said() { grep -v '^Running scripts/' <<< "${OUTPUT}" | grep -qF -- "$1"; }
not_script_said() { ! script_said "$1"; }
not_said() { ! said "$1"; }
not_run() { [[ -z "$(find "${STUB}/calls" -name '*.args')" ]]; }
calls() { find "${STUB}/calls" -name '*.args' | wc -l | tr -d ' '; }
# has N ARG...: saf call N got each of these arguments, in this order, next
# to each other.
has() {
    local file="${STUB}/calls/$1.args"
    shift
    [[ -f "${file}" ]] && grep -qzF -- "$(printf '%s\n' "$@")" "${file}"
}
lacks() { [[ -f "${STUB}/calls/$1.args" ]] && ! grep -qxF -- "$2" "${STUB}/calls/$1.args"; }
meta() { grep -qxF -- "$2" "${STUB}/calls/$1.meta"; }
exported() { grep -qF -- "$1" "${WORK}/bash_env"; }
# env_value NAME: the value BASH_ENV exports for NAME.
# shellcheck disable=SC1091 # the file the scripts write
env_value() { (unset "$1"; source "${WORK}/bash_env"; printf '%s' "${!1-}"); }
json_is() { [[ "$(jq -c "$2" "$1" 2> /dev/null)" == "$3" ]]; }

echo "--- convert ---"
run convert from=sarif input=results.sarif
check "convert: succeeds" rc_is 0
check "convert: runs saf convert sarif2hdf with the input made absolute" \
    has 1 convert sarif2hdf -i "${JOB}/results.sarif" -o
check "convert: never passes -w by default" lacks 1 -w
check "convert: runs the SAF CLI in a directory of its own" bash -c "! grep -qx 'cwd=${JOB}' '${STUB}/calls/1.meta'"
check "convert: with SAF_SKIP_NEW_VERSION_CHECK=true" meta 1 skip=true
check "convert: leaves no saf-cli.log in the working directory" test ! -e "${JOB}/saf-cli.log"
check "convert: writes <report_name>.json, the from by default" json_is "${OUT}/sarif.json" '.profiles[0].name' '"converted"'
check "convert: lists it in <report_name>.files" grep -qxF "${OUT}/sarif.json" "${OUT}/sarif.files"
check "convert: exports SAF_HDF_FILES" [ "$(env_value SAF_HDF_FILES)" == "${OUT}/sarif.json" ]
check "convert: prints the controls" said "1 profile(s), 1 control(s)"

run convert from=sarif input=results.sarif report_name=semgrep hdf_env_var=MY_HDF
check "convert: report_name names the file" test -f "${OUT}/semgrep.json"
check "convert: hdf_env_var names the variable" [ "$(env_value MY_HDF)" == "${OUT}/semgrep.json" ]

run convert from=nessus input=results.sarif -- STUB_CONVERT=multi
check "convert: several files succeed" rc_is 0
check "convert: several files are <report_name>-<name>.json, made safe" \
    test -f "${OUT}/nessus-host-a.json" -a -f "${OUT}/nessus-host_b.json"
check "convert: exports every file, one per line" \
    [ "$(env_value SAF_HDF_FILES)" == "${OUT}/nessus-host_b.json"$'\n'"${OUT}/nessus-host-a.json" ]
run convert from=nessus input=results.sarif
check "convert: a later run removes the files an earlier one wrote" \
    test -f "${OUT}/nessus.json" -a ! -e "${OUT}/nessus-host-a.json" -a ! -e "${OUT}/nessus-host_b.json"

run convert from=prowler input=results.sarif -- STUB_CONVERT=dir
check "convert: a directory of files succeeds" rc_is 0
check "convert: passes the directory as -o" has 1 -o "${WORK}" && grep -qx '.*/out/prowler' "${STUB}/calls/1.args"
check "convert: names a directory's files after it" test -f "${OUT}/prowler-one.json" -a -f "${OUT}/prowler-two.json"

for mode in warn none bad exit; do
    run convert from=sarif report_name="fail-${mode}" input=results.sarif -- "STUB_CONVERT=${mode}"
    check "convert: fails when the converter answers ${mode}" rc_is 1
    check "convert: leaves no HDF when the converter answers ${mode}" test ! -e "${OUT}/fail-${mode}.json"
done
run convert from=sarif input=results.sarif -- STUB_CONVERT=warn
check "convert: shows the SAF CLI's warning" said "Unable to process input file"
check "convert: says the SAF CLI exits 0 even so" said "it exits 0 even so"
check "convert: exports nothing when it fails" test ! -s "${WORK}/bash_env"
run convert from=sarif input=results.sarif -- STUB_CONVERT=bad
check "convert: says a file isn't HDF" said "which is not HDF results"

run convert from=trufflehog input=results.sarif
check "convert: refuses trufflehog, whose HDF holds the secrets" rc_is 2
check "convert: says to convert TruffleHog's SARIF" said "with from: sarif"
check "convert: refuses trufflehog before saf runs" not_run
run convert from=sonarqube input=results.sarif
check "convert: refuses a converter that reads a service" rc_is 2
run convert from=bogus input=results.sarif
check "convert: refuses an unknown converter" rc_is 2
run convert from=sarif input=missing.sarif
check "convert: refuses a missing input" rc_is 2
check "convert: refuses a missing input before saf runs" not_run
run convert from=veracode input=results.sarif include_raw=true
check "convert: refuses include_raw where the converter has no -w" rc_is 2
run convert from=sarif input=results.sarif include_raw=true
check "convert: include_raw passes -w" has 1 -w
run convert from=zap input=results.sarif
check "convert: zap needs --name" rc_is 2
run convert from=zap input=results.sarif "extra_args=--name https://example.com"
check "convert: zap's --name passes" has 1 --name https://example.com
run convert from=asff input=results.sarif "extra_args=--securityHub standards.json" -- STUB_CONVERT=dir
check "convert: asff's --securityHub file is made absolute" has 1 --securityHub "${JOB}/standards.json"
run convert from=asff input=results.sarif "extra_args=--securityHub nowhere.json"
check "convert: refuses a --securityHub file that isn't there" rc_is 2
run convert from=sarif input=results.sarif "extra_args=-o /tmp/elsewhere.json"
check "convert: refuses options it sets itself" rc_is 2
run convert from=sarif input=results.sarif "extra_args=--name x"
check "convert: refuses another converter's options" rc_is 2
run convert from=sarif input=results.sarif "hdf_env_var=1BAD"
check "convert: refuses a bad hdf_env_var" rc_is 2
run convert from=sarif input=results.sarif report_name=../x
check "convert: refuses a report_name that isn't a plain name" rc_is 1
# shellcheck disable=SC2016 # expanded by the stand-in circleci CLI
run convert from=sarif 'input=$ORB_TEST_VAR' -- ORB_TEST_VAR=results.sarif
check "convert: expands environment variables in input" has 1 -i "${JOB}/results.sarif"
mkdir -p "${WORK}/nocli"
for tool in jq bash env cat sed awk grep find sort uniq mktemp mkdir rm mv cp date tr head tail wc dirname basename paste od sha256sum sha512sum printf; do
    path=$(command -v "${tool}") && ln -sf "${path}" "${WORK}/nocli/${tool}"
done
ln -sf "${WORK}/bin/saf" "${WORK}/nocli/saf"
OUTPUT=$(cd "${JOB}" && env -u SAF_HDF_FILES HOME="${HOME_DIR}" PATH="${WORK}/nocli" BASH_ENV="${WORK}/bash_env" \
    STUB_DIR="${STUB}" bash "${ROOT}/tests/run_command.sh" convert "output_dir=${OUT}" from=sarif \
    'input=results.sarif' 2>&1)
RC=$?
check "convert: runs without the CircleCI CLI, taking values as they are" rc_is 0

echo "--- threshold ---"
run threshold input=hdf/good.json "template_inline={compliance.min: 80}, {failed.critical.max: 0}"
check "threshold: passes a file that meets the thresholds" rc_is 0
check "threshold: runs summary, then validate threshold, on the file" has 1 view summary -i "${JOB}/hdf/good.json"
check "threshold: runs validate threshold with -T" has 2 validate threshold -i "${JOB}/hdf/good.json" -T
check "threshold: hands the SAF CLI the thresholds nested" \
    json_is "${STUB}/calls/2.template" . '{"compliance":{"min":80},"failed":{"critical":{"max":0}}}'
check "threshold: writes the report" json_is "${OUT}/threshold.json" '[.files, .passed, .failed, .errors]' '[1,1,0,0]'
check "threshold: reports the counts" json_is "${OUT}/threshold.json" '.results[0].counts.failed.total' '1'
check "threshold: reports the compliance" json_is "${OUT}/threshold.json" '.results[0].compliance' '50'
check "threshold: writes JUnit" grep -q '<testcase classname="threshold" name="good.json (good)">' "${OUT}/junit/threshold.xml"
check "threshold: prints the counts" said "compliance 50%; passed 1, failed 1"
check "threshold: writes no run record by default" test ! -e "${OUT}/threshold.run-record.json"

cat > "${JOB}/threshold.yml" << 'EOF'
# Thresholds, nested and dotted together
compliance:
  min: 60
failed.critical.max: 0
failed:
  high:
    max: 2
  total.min: 1
  total.max: 9   # SAF's dotted form would keep only this one
passed:
  critical:
    controls:
      - V-1
      - "V-2"
  high.controls: [V-3]
EOF
run threshold input=hdf/good.json template_file=threshold.yml run_record=true
check "threshold: reads a template file" rc_is 0
check "threshold: keeps a min and a max of the same status" \
    json_is "${STUB}/calls/2.template" '.failed.total' '{"min":1,"max":9}'
check "threshold: merges dotted and nested keys" \
    json_is "${STUB}/calls/2.template" '[.compliance.min, .failed.critical.max, .failed.high.max]' '[60,0,2]'
check "threshold: reads control lists, block and flow" \
    json_is "${STUB}/calls/2.template" '[.passed.critical.controls, .passed.high.controls]' '[["V-1","V-2"],["V-3"]]'
check "threshold: writes the run record" json_is "${OUT}/threshold.run-record.json" '[.command, .outcome, .tool.name]' \
    '["threshold","passed","saf"]'

run threshold "input=hdf/good.json hdf/bad.json" "template_inline={failed.critical.max: 0}" run_record=true
check "threshold: fails when a file doesn't meet the thresholds" rc_is 1
check "threshold: shows the SAF CLI's reason" said "failed.critical.max: Threshold not met"
check "threshold: checks every file" json_is "${OUT}/threshold.json" '[.passed, .failed]' '[1,1]'
check "threshold: puts the reason in JUnit" grep -q '<failure message="failed.critical.max: Threshold not met' "${OUT}/junit/threshold.xml"
check "threshold: records the failure" json_is "${OUT}/threshold.run-record.json" '.outcome' '"failed"'
run threshold input=hdf/bad.json "template_inline={failed.critical.max: 0}" report_only=true run_record=true
check "threshold: report_only passes a file that doesn't meet them" rc_is 0
check "threshold: report_only warns" said "WARN: 1 file does not meet the thresholds."
check "threshold: records findings-reported" json_is "${OUT}/threshold.run-record.json" '.outcome' '"failed-reported"'
run threshold input=hdf/broken.json "template_inline={failed.critical.max: 0}" report_only=true run_record=true
check "threshold: fails without a verdict, whatever report_only says" rc_is 1
check "threshold: says there is no verdict" said "so there is no verdict"
check "threshold: records the error" json_is "${OUT}/threshold.run-record.json" '[.outcome, .exit_code]' '["error",1]'
run threshold input=hdf/good.json "template_inline={failed.critical.max: 0}" -- STUB_SUMMARY=fail
check "threshold: fails when the summary fails" rc_is 1
check "threshold: says the summary failed" said "saf view summary could not summarize it"
run threshold input=hdf/not-hdf.json "template_inline={failed.critical.max: 0}"
check "threshold: refuses a file that isn't HDF" rc_is 1
check "threshold: refuses it before validate threshold runs" not_run

# template TEXT: runs threshold with TEXT as the template file.
template() {
    printf '%s\n' "$1" > "${JOB}/t.yml"
    run threshold input=hdf/good.json template_file=t.yml
}
template "failed.critical.maximum: 0"
check "threshold: refuses a key the SAF CLI would skip" rc_is 2
check "threshold: names it" said "failed.critical.maximum is not a threshold the SAF CLI checks"
check "threshold: refuses it before saf runs" not_run
template "no_impact.total.max: 0"
check "threshold: checks no_impact.total.max, which validate threshold skips" rc_is 0
template "no_impact.total.min: 1"
check "threshold: fails a file that doesn't meet no_impact.total.min" rc_is 1
check "threshold: says which" said "no_impact.total.min: Threshold not met. Number of received total no_impact controls (0) is less"
template "compliance.max: 0"
check "threshold: checks a compliance.max of 0, which validate threshold skips" rc_is 1
check "threshold: says so" said "Overall compliance maximum was not satisfied (50%, at most 0%)"
template "no_impact.total: 0"$'\n'"no_impact.total.max: 4"
check "threshold: refuses no_impact.total with a minimum or maximum" rc_is 2
template "compliance.min: 101"
check "threshold: refuses a compliance over 100" rc_is 2
template "failed.total.max: two"
check "threshold: refuses a value that isn't a whole number" rc_is 2
template "failed.critical.controls: []"
check "threshold: refuses an empty control list, which the SAF CLI always fails" rc_is 2
check "threshold: suggests a max of 0" said "set failed.critical.max: 0 instead"
template "failed.total: 3"$'\n'"failed.total.max: 4"
check "threshold: refuses an exact count with a minimum or maximum" rc_is 2
template "failed:"$'\n\t'"total: 3"
check "threshold: refuses tabs" rc_is 2
template "failed: {total: 3}"
check "threshold: refuses flow mappings" rc_is 2
template "failed:"
check "threshold: refuses a key without a value" rc_is 2
template "# nothing"
check "threshold: refuses a template with no thresholds" rc_is 2
run threshold input=hdf/good.json template_file=t.yml "template_inline={failed.total.max: 0}"
check "threshold: refuses both template_file and template_inline" rc_is 2
run threshold input=hdf/good.json
check "threshold: needs a template" rc_is 2

run threshold "template_inline={failed.critical.max: 0}" -- "SAF_HDF_FILES=${JOB}/hdf/good.json"
check "threshold: reads SAF_HDF_FILES when input is empty" has 2 -i "${JOB}/hdf/good.json"
run threshold "template_inline={failed.critical.max: 0}"
check "threshold: fails when input is empty without SAF_HDF_FILES" rc_is 1
check "threshold: says so" said "no convert step exported SAF_HDF_FILES"
run threshold "input=hdf/*.json" "template_inline={failed.critical.max: 0}"
check "threshold: expands globs" rc_is 1
check "threshold: refuses the non-HDF file a glob matched" said "not-hdf.json is not HDF"
run threshold "input=hdf/missing-*.json" "template_inline={failed.critical.max: 0}"
check "threshold: fails on a glob that matches nothing" rc_is 1
jq '.profiles += [{name: "second", controls: []}]' "${JOB}/hdf/good.json" > "${JOB}/two-profiles.json"
run threshold input=two-profiles.json "template_inline={failed.critical.max: 0}"
check "threshold: warns that only the first profile is checked" said "checks only ${JOB}/two-profiles.json's first profile, good, not second"
jq '.profiles += [{name: "dep", parent_profile: "good", controls: []}]' "${JOB}/hdf/good.json" > "${JOB}/overlay.json"
run threshold input=overlay.json "template_inline={failed.critical.max: 0}"
check "threshold: doesn't warn of a dependency profile" not_said "checks only"

echo "--- summary ---"
run summary "input=hdf/good.json hdf/bad.json"
check "summary: succeeds" rc_is 0
check "summary: summarizes every file in one call" has 1 view summary -i "${JOB}/hdf/good.json" "${JOB}/hdf/bad.json" -f markdown
check "summary: prints the table" said "| Compliance: 50"
check "summary: writes json and markdown by default" test -f "${OUT}/summary.json" -a -f "${OUT}/summary.md" -a ! -e "${OUT}/summary.yml"
check "summary: the JSON has both profiles" json_is "${OUT}/summary.json" '[.[].profileName]' '["bad","good"]'
run summary input=hdf/good.json formats=yaml -- "GITHUB_STEP_SUMMARY=${WORK}/step-summary.md"
check "summary: writes yaml" test -f "${OUT}/summary.yml" -a ! -e "${OUT}/summary.json"
check "summary: adds the table to GitHub's job summary" grep -q '### SAF CLI summary' "${WORK}/step-summary.md"
rm -f "${WORK}/step-summary.md"
run summary input=hdf/good.json step_summary=false -- "GITHUB_STEP_SUMMARY=${WORK}/step-summary.md"
check "summary: step_summary false leaves GitHub's job summary alone" test ! -e "${WORK}/step-summary.md"
run summary input=hdf/good.json formats=pdf
check "summary: refuses an unknown format" rc_is 2
run summary input=hdf/good.json -- STUB_SUMMARY=fail
check "summary: fails when the SAF CLI does" rc_is 1
check "summary: shows why" said "Unexpected token"

echo "--- export ---"
run export input=hdf/good.json format=ckl
check "export: ckl succeeds" rc_is 0
check "export: runs hdf2ckl" has 1 convert hdf2ckl -i "${JOB}/hdf/good.json"
check "export: names the checklist after the HDF file" test -f "${OUT}/good.ckl"
run export input=hdf/good.json format=ckl report_name=rhel9 "extra_args=--hostname web01 --metadata threshold.yml"
check "export: report_name names it" test -f "${OUT}/rhel9.ckl"
check "export: passes ckl's options" has 1 --hostname web01
check "export: makes --metadata absolute" has 1 --metadata "${JOB}/threshold.yml"
run export "input=hdf/good.json hdf/bad.json" format=xccdf
check "export: xccdf writes a file per HDF file" test -f "${OUT}/good.xml" -a -f "${OUT}/bad.xml"
check "export: runs once per file" [ "$(calls)" -eq 2 ]
run export "input=hdf/good.json hdf/bad.json" format=csv report_name=all "extra_args=-t --fields ID,Status"
check "export: csv with report_name and several files" test -f "${OUT}/all-good.csv" -a -f "${OUT}/all-bad.csv"
check "export: passes csv's options" has 1 -t --fields ID,Status
run export "input=hdf/good.json hdf/bad.json" format=html "extra_args=--type Executive"
check "export: html puts every file in one" test -f "${OUT}/good.html"
check "export: html runs once, with every file" has 1 -i "${JOB}/hdf/good.json" "${JOB}/hdf/bad.json" -o
run export input=hdf/good.json format=caat report_name=caat
check "export: caat writes an XLSX" test -f "${OUT}/caat.xlsx"
for mode in warn bad none; do
    run export input=hdf/good.json format=ckl report_name="x-${mode}" -- "STUB_EXPORT=${mode}"
    check "export: fails when the export answers ${mode}" rc_is 1
    check "export: leaves nothing when the export answers ${mode}" test ! -e "${OUT}/x-${mode}.ckl"
done
run export input=hdf/good.json format=ckl "extra_args=--type Executive"
check "export: refuses another format's options" rc_is 2
run export input=hdf/good.json format=pdf
check "export: refuses an unknown format" rc_is 2
mkdir -p "${JOB}/other"
cp "${JOB}/hdf/good.json" "${JOB}/other/good.json"
run export "input=hdf/good.json other/good.json" format=ckl
check "export: refuses two files that would be exported to one" rc_is 2
run export input=hdf/not-hdf.json format=ckl
check "export: refuses a file that isn't HDF" rc_is 1

echo "--- upload_heimdall ---"
SERVER="${WORK}/server"
mkdir -p "${SERVER}"
python3 "${ROOT}/tests/fake_heimdall.py" "${SERVER}" &
SERVER_PID=$!
for _ in $(seq 1 100); do
    [[ -f "${SERVER}/port" ]] && break
    sleep 0.1
done
URL="http://127.0.0.1:$(cat "${SERVER}/port")"
uploads() { if [[ -f "${SERVER}/uploads.jsonl" ]]; then wc -l < "${SERVER}/uploads.jsonl" | tr -d ' '; else echo 0; fi; }
settings() { printf '%s\n' "$1" > "${SERVER}/settings.json"; rm -f "${SERVER}/uploads.jsonl"; }
KEY="test-key"

settings '{}'
run upload_heimdall "url=${URL}" "input=hdf/good.json hdf/bad.json" "evaluation_tags=main, build 7" "groups=3 4" \
    -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: succeeds" rc_is 0
check "upload_heimdall: uploads each file" [ "$(uploads)" -eq 2 ]
check "upload_heimdall: sends the file as data, with its name" \
    json_is "${SERVER}/uploads.jsonl" '.files.data[0].filename' $'"good.json"\n"bad.json"'
check "upload_heimdall: sends the file unchanged" \
    json_is "${SERVER}/uploads.jsonl" '.files.data[0].sha256' "$(printf '"%s"\n' "$(sha256sum < "${JOB}/hdf/good.json" | cut -d' ' -f1)" "$(sha256sum < "${JOB}/hdf/bad.json" | cut -d' ' -f1)")"
check "upload_heimdall: sends filename, public, tags and groups once each" \
    json_is <(head -n 1 "${SERVER}/uploads.jsonl") '.fields' '{"filename":["good.json"],"public":["false"],"evaluationTags":["main,build 7"],"groups":["3,4"]}'
check "upload_heimdall: lists the evaluations" json_is "${OUT}/heimdall.json" '[.uploads[].url]' \
    "[\"${URL}/results/1001\",\"${URL}/results/1002\"]"
check "upload_heimdall: exports their URLs" [ "$(env_value HEIMDALL_EVALUATION_URLS)" == "${URL}/results/1001 ${URL}/results/1002" ]
check "upload_heimdall: never shows the key" not_said "${KEY}"

settings '{}'
run upload_heimdall "url=${URL}" input=hdf/good.json public=true -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: public sends true" json_is "${SERVER}/uploads.jsonl" '.fields.public' '["true"]'
check "upload_heimdall: sends no tags or groups unless asked" json_is "${SERVER}/uploads.jsonl" '.fields | keys' '["filename","public"]'

settings '{"key": "other-key"}'
run upload_heimdall "url=${URL}" input=hdf/good.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: fails on a wrong key" rc_is 1
check "upload_heimdall: says the key was refused" said "403: Heimdall refused the API key in HEIMDALL_API_KEY"
check "upload_heimdall: exports nothing when it fails" test ! -s "${WORK}/bash_env"
settings '{"api_keys": false}'
run upload_heimdall "url=${URL}" input=hdf/good.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: fails when the server takes no API keys" rc_is 1
check "upload_heimdall: says to set API_KEY_SECRET" said "API_KEY_SECRET"
check "upload_heimdall: sends nothing to a server without API keys" [ "$(uploads)" -eq 0 ]
settings '{"fail": [2]}'
run upload_heimdall "url=${URL}" "input=hdf/good.json hdf/bad.json" -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: fails when an upload fails" rc_is 1
check "upload_heimdall: never retries an upload" [ "$(uploads)" -eq 2 ]
check "upload_heimdall: names what was stored before it" said "These were stored before it: ${URL}/results/1001"
settings '{"garbage": true}'
run upload_heimdall "url=${URL}" input=hdf/good.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: fails on an answer without an id" rc_is 1
settings '{}'
run upload_heimdall "url=${URL}" input=hdf/not-hdf.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: refuses a file that isn't HDF" rc_is 1
check "upload_heimdall: uploads nothing then" [ "$(uploads)" -eq 0 ]
run upload_heimdall "url=${URL}" input=hdf/good.json
check "upload_heimdall: fails without the key" rc_is 2
check "upload_heimdall: names the variable" said "The variable HEIMDALL_API_KEY (api_key) is empty or not set"
run upload_heimdall "url=http://heimdall.example.com" input=hdf/good.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: refuses http to another machine" rc_is 2
run upload_heimdall "url=https://user:pw@heimdall.example.com" input=hdf/good.json -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: refuses credentials in url" rc_is 2
check "upload_heimdall: never shows them" not_script_said "user:pw"
run upload_heimdall "url=${URL}" input=hdf/good.json groups=admins -- "HEIMDALL_API_KEY=${KEY}"
check "upload_heimdall: refuses a group that isn't an ID" rc_is 2
run upload_heimdall "url=${URL}" input=hdf/good.json api_key=MY_KEY -- "MY_KEY=${KEY}"
check "upload_heimdall: api_key names the variable" rc_is 0

echo "--- run records ---"
if python3 -c 'import jsonschema' 2> /dev/null; then
    bad=0
    for record in "${WORK}/records/"*.json; do
        [[ -f "${record}" ]] || continue
        if ! python3 - "${ROOT}/schemas/run-record.v1.json" "${record}" << 'EOF'
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))
EOF
        then
            bad=$((bad + 1))
        fi
    done
    check "every run record ($(find "${WORK}/records" -name '*.json' | wc -l | tr -d ' ')) matches the schema" [ "${bad}" -eq 0 ]
else
    echo "skip: jsonschema is not installed, so the run records were not checked against the schema"
fi

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All checks passed."
