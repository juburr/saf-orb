#!/bin/bash
#
# Checks HDF results against compliance thresholds for the threshold command,
# with the SAF CLI's validate threshold, once per HDF file.
#
# The SAF CLI exits 1 with an "Error: ..." line for the first threshold a file
# doesn't meet, and prints "All validation tests passed" when it meets them
# all; anything else (a template or file it can't read) it reports as a
# warning, exiting 0. It reads only the first profile of each file, skips
# keys it doesn't know, and loses a min when a max follows it in the dotted
# form. So the step reads the template itself (template_file or
# template_inline), refuses anything the SAF CLI would misread, and hands it
# the thresholds as one nested JSON document. Each file's counts come from
# the SAF CLI's view summary, which counts as validate threshold does. Two
# thresholds validate threshold skips, though saf generate threshold writes
# them, are checked here from those counts: no_impact.total.min and .max,
# and a compliance.max of 0.
#
# A file that doesn't meet the thresholds fails the step unless report_only
# is true. A file the SAF CLI couldn't check fails it either way.
#
# Parameters (CircleCI passes them as PARAM_* variables):
#   PARAM_INPUT, PARAM_TEMPLATE_FILE, PARAM_TEMPLATE_INLINE, PARAM_OUTPUT_DIR,
#   PARAM_REPORT_NAME, PARAM_JUNIT, PARAM_RUN_RECORD, PARAM_REPORT_ONLY

set -euo pipefail

if [[ -z "${SCRIPT_SAF_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_SAF_LIB is not set; run this script through the orb's threshold command." >&2
    exit 1
fi
eval "${SCRIPT_SAF_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Reports ---
# Checked and cleared before anything else, so a run that stops on a
# parameter never leaves an earlier run's reports to be stored as its own;
# never a file it reads, though: an HDF file or the template. Neither is
# expanded: the steps that store the reports read them as given.
REPORT_NAME=${PARAM_REPORT_NAME}
sf_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${SF_BASE}.json"
JUNIT_FILE="${SF_OUT}/junit/${REPORT_NAME}.xml"
RECORD="${SF_BASE}.run-record.json"
sf_inputs input "${PARAM_INPUT}"
TEMPLATE_FILE=$(sf_path "$(sf_subst "${PARAM_TEMPLATE_FILE}")")
# shellcheck disable=SC2034 # read by sf_reports_apart
SF_OTHER_INPUTS=(${TEMPLATE_FILE:+"${TEMPLATE_FILE}"})
sf_reports_apart "${REPORT}" "${JUNIT_FILE}" "${RECORD}"
rm -f "${REPORT}" "${JUNIT_FILE}" "${RECORD}"
sf_inputs_check

TEMPLATE_INLINE=$(sf_subst "${PARAM_TEMPLATE_INLINE}")
JUNIT=$(sf_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(sf_bool run_record "${PARAM_RUN_RECORD}")
REPORT_ONLY=$(sf_bool report_only "${PARAM_REPORT_ONLY}")

# usage MESSAGE...: stops the step on a parameter that can't work, before
# anything runs.
usage() {
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    exit 2
}

# --- The template ---
# TEMPLATE_AWK reads a threshold template in the plain subset of YAML that
# templates need: keys nested by indentation or written with dots
# (failed.critical.max), whole numbers, and lists of control IDs, block or
# [flow]. It prints one line per value: "S<TAB>key<TAB>number", "L<TAB>key<TAB>id"
# for each control ID, "E<TAB>key" for an empty list and "N<TAB>key" for a
# key with no value. Anything else (anchors, flow mappings, multi-line
# strings, tabs) prints "X<TAB>line N: why" and stops: the step refuses what
# it can't read exactly, rather than let the SAF CLI read it differently.
# shellcheck disable=SC2016 # awk program, not shell
TEMPLATE_AWK='
function err(msg) { printf "X\tline %d: %s\n", NR, msg; bad = 1; exit 1 }
function unquote(v,   q) {
    q = substr(v, 1, 1)
    if (q == "\"" || q == "'\''") {
        if (length(v) < 2 || substr(v, length(v), 1) != q) err("unterminated quote: " v)
        v = substr(v, 2, length(v) - 2)
        if (index(v, q) || index(v, "\\")) err("a quoted value can'\''t hold quotes or backslashes: " v)
    }
    return v
}
function strip_comment(s,   i, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "'\''") { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) return substr(s, 1, i - 1)
    }
    return s
}
function close_top() {
    if (kind[depth] == "open") printf "N\t%s\n", full[depth]
    depth--
}
{
    sub(/\r$/, "")
    line = strip_comment($0)
    sub(/[ \t]+$/, "", line)
    if (line ~ /^[ \t]*$/) next
    if (line == "---" && !started) next
    started = 1
    match(line, /^ */)
    n = RLENGTH
    rest = substr(line, n + 1)
    if (substr(rest, 1, 1) == "\t") err("indent with spaces, not tabs")
    if (rest == "-" || substr(rest, 1, 2) == "- ") {
        item = substr(rest, 2)
        sub(/^[ \t]+/, "", item)
        while (depth > 0 && ind[depth] > n) close_top()
        if (depth == 0 || (kind[depth] != "open" && kind[depth] != "list")) err("a list item must be under a key such as failed.critical.controls")
        if (item == "" || item ~ /^[[{&*!|>%@`-]/ || item ~ /: /) err("a list item must be a control ID, not " item)
        kind[depth] = "list"
        printf "L\t%s\t%s\n", full[depth], unquote(item)
        next
    }
    if (!match(rest, /^[A-Za-z0-9_.]+:( |$)/)) err("expected key: value, not " rest)
    key = substr(rest, 1, RLENGTH)
    sub(/: ?$/, "", key)
    value = substr(rest, RLENGTH + 1)
    sub(/^[ \t]+/, "", value)
    while (depth > 0 && ind[depth] >= n) close_top()
    if (depth > 0) {
        if (kind[depth] == "list") err("key " key " follows a list at the same level")
        kind[depth] = "map"
    }
    path = (depth > 0 ? full[depth] "." : "") key
    if (path in seen) err(path " appears twice")
    seen[path] = 1
    if (value == "") {
        depth++
        ind[depth] = n
        full[depth] = path
        kind[depth] = "open"
        next
    }
    if (value ~ /^\[.*\]$/) {
        inner = substr(value, 2, length(value) - 2)
        if (inner ~ /^[ \t]*$/) { printf "E\t%s\n", path; next }
        count = split(inner, items, ",")
        for (j = 1; j <= count; j++) {
            item = items[j]
            gsub(/^[ \t]+|[ \t]+$/, "", item)
            if (item == "" || item ~ /^[[{&*!|>%@`]/) err("a list item must be a control ID, not " item)
            printf "L\t%s\t%s\n", path, unquote(item)
        }
        next
    }
    if (value ~ /^[[{&*!|>%@`]/) err("unsupported YAML in " key ": " value)
    printf "S\t%s\t%s\n", path, unquote(value)
}
END { if (!bad) while (depth > 0) close_top() }
'

if [[ -n "${TEMPLATE_FILE}" && -n "${TEMPLATE_INLINE}" ]]; then
    usage "Set template_file or template_inline, not both."
fi
if [[ -n "${TEMPLATE_FILE}" ]]; then
    if [[ ! -f "${TEMPLATE_FILE}" || ! -r "${TEMPLATE_FILE}" ]]; then
        usage "template_file ${TEMPLATE_FILE} is not a readable file."
    fi
    TEMPLATE_FROM=template_file
    TEMPLATE_TEXT=$(cat "${TEMPLATE_FILE}")
elif [[ -n "${TEMPLATE_INLINE}" ]]; then
    # The SAF CLI's own inline form: {compliance.min: 80}, {failed.total.max: 2}
    TEMPLATE_FROM=template_inline
    TEMPLATE_TEXT=$(tr ',' '\n' <<< "${TEMPLATE_INLINE}" | tr -d '{}' | sed 's/^[[:space:]]*//')
else
    usage "Set template_file to a threshold template (YAML), or template_inline to thresholds such as" \
        "{compliance.min: 80}, {failed.critical.max: 0}."
fi

PARSED=$(awk "${TEMPLATE_AWK}" <<< "${TEMPLATE_TEXT}") || true
SCALARS=()
LISTS=()
OWN=()
COUNT_RE='^(compliance\.(min|max)|(passed|failed|skipped|no_impact|error)\.total|(passed|failed|skipped|no_impact|error)\.total\.(min|max)|(passed|failed|skipped|no_impact|error)\.(critical|high|medium|low)\.(min|max)|no_impact\.none\.(min|max))$'
CONTROLS_RE='^((passed|failed|skipped|no_impact|error)\.(critical|high|medium|low)|no_impact\.none)\.controls$'
while IFS=$'\t' read -r kind key value; do
    case "${kind}" in
        X) usage "${TEMPLATE_FROM}: ${key}${value:+ ${value}}" ;;
        N) usage "${TEMPLATE_FROM}: ${key} has no value." ;;
        E)
            usage "${TEMPLATE_FROM}: ${key} is an empty list, which the SAF CLI fails whatever the results hold." \
                "To require that a status and severity has no controls, set ${key%.controls}.max: 0 instead."
            ;;
        S)
            if ! sf_match "${key}" "${COUNT_RE}"; then
                usage "${TEMPLATE_FROM}: ${key} is not a threshold the SAF CLI checks, so it would be skipped." \
                    "Thresholds are compliance.min and .max, <status>.total, <status>.total.min and .max, and" \
                    "<status>.<severity>.min, .max and .controls, for the statuses passed, failed, skipped," \
                    "no_impact and error, and the severities critical, high, medium and low (and none for no_impact)."
            fi
            if ! sf_match "${value}" '^[0-9]{1,9}$'; then
                usage "${TEMPLATE_FROM}: ${key} must be a whole number, not '${value}'."
            fi
            value=$((10#${value}))
            if [[ "${key}" == compliance.* ]] && ((value > 100)); then
                usage "${TEMPLATE_FROM}: ${key} is a percentage, at most 100, not ${value}."
            fi
            # Thresholds validate threshold skips, which this step checks.
            if [[ "${key}" == no_impact.total.min || "${key}" == no_impact.total.max \
                || ("${key}" == compliance.max && "${value}" -eq 0) ]]; then
                OWN+=("${key}" "${value}")
            fi
            SCALARS+=("${key}" "${value}")
            ;;
        L)
            if [[ "${key}" == *.total.controls ]] || ! sf_match "${key}" "${CONTROLS_RE}"; then
                usage "${TEMPLATE_FROM}: ${key} is not a list the SAF CLI checks: lists of control IDs go in" \
                    "<status>.<severity>.controls, such as failed.critical.controls."
            fi
            if ! sf_match "${value}" '^[^[:space:]]+$'; then
                usage "${TEMPLATE_FROM}: '${value}' in ${key} is not a control ID."
            fi
            LISTS+=("${key}" "${value}")
            ;;
    esac
done <<< "${PARSED}"
if [[ ${#SCALARS[@]} -eq 0 && ${#LISTS[@]} -eq 0 ]]; then
    usage "${TEMPLATE_FROM} holds no thresholds."
fi
for ((i = 0; i < ${#SCALARS[@]}; i += 2)); do
    for status in passed failed skipped no_impact error; do
        if [[ "${SCALARS[i]}" == "${status}.total" ]] \
            && printf '%s\n' "${SCALARS[@]}" | grep -qx "${status}\.total\.\(min\|max\)"; then
            usage "${TEMPLATE_FROM}: ${status}.total can't be both an exact count and have a minimum or maximum."
        fi
    done
done

sf_require_jq
# The thresholds as the SAF CLI's nested template, for -T: JSON, which its
# YAML reader reads as is. Every value is an object, so it doesn't run its
# flattened-template conversion, which keeps one of failed.total.min and
# failed.total.max.
THRESHOLDS=$({
    for ((i = 0; i < ${#SCALARS[@]}; i += 2)); do
        jq -cn --arg key "${SCALARS[i]}" --argjson value "${SCALARS[i + 1]}" '{key: $key, value: $value}'
    done
    for ((i = 0; i < ${#LISTS[@]}; i += 2)); do
        jq -cn --arg key "${LISTS[i]}" --arg id "${LISTS[i + 1]}" '{key: $key, id: $id}'
    done
} | jq -cs 'reduce .[] as $e ({};
    ($e.key | split(".")) as $path
    | if $e | has("id") then setpath($path; (getpath($path) // []) + [$e.id]) else setpath($path; $e.value) end)')

SF_WORK=$(mktemp -d)
trap 'rm -rf "${SF_WORK}"' EXIT
printf '%s\n' "${THRESHOLDS}" > "${SF_WORK}/threshold.json"

# --- Reports ---
RESULTS="[]"
# Why there is no verdict, when stop ends the step.
STOP_MESSAGE=""

# write_reports OUTCOME EXIT_CODE: writes the JSON report, the JUnit and the
# run record from RESULTS.
write_reports() {
    local reports=() cases
    jq -n --argjson thresholds "${THRESHOLDS}" --argjson results "${RESULTS}" --arg error "${STOP_MESSAGE}" '{
        thresholds: $thresholds,
        error: (if $error == "" then null else $error end),
        files: ($results | length),
        passed: ([$results[] | select(.outcome == "passed")] | length),
        failed: ([$results[] | select(.outcome == "failed")] | length),
        errors: ([$results[] | select(.outcome == "error")] | length),
        results: $results
    }' > "${REPORT}"
    reports+=("${REPORT}")
    if [[ "${JUNIT}" == true ]]; then
        cases=$(jq -c --arg suite "${REPORT_NAME}" '[.[] | {
            classname: $suite,
            name: "\(.file | split("/") | last) (\(.profile // "no profile"))",
            status: (if .outcome == "passed" then "passed" else "failed" end),
            message: (if .outcome == "error" then "No verdict: \(.message)" else .message end),
            detail: ("compliance: \(.compliance // "unknown")%\n"
                + ((.counts // {}) | to_entries | map("\(.key): \(.value.total // 0)") | join("\n")))
        }]' <<< "${RESULTS}")
        # A step that stopped before checking a file fails a test of its own,
        # rather than leaving the one passing test sf_junit writes for none.
        if [[ -n "${STOP_MESSAGE}" && "${cases}" == "[]" ]]; then
            cases=$(jq -cn --arg suite "${REPORT_NAME}" --arg message "${STOP_MESSAGE}" \
                '[{classname: $suite, name: "threshold check", status: "failed", message: "No verdict: \($message)"}]')
        fi
        sf_junit "${JUNIT_FILE}" "${REPORT_NAME}" "${cases}"
        reports+=("${JUNIT_FILE}")
    fi
    if [[ "${RUN_RECORD}" == true ]]; then
        write_record "$1" "$2" ${reports[@]+"${reports[@]}"}
    fi
}

# write_record OUTCOME EXIT_CODE REPORT...: writes the run record,
# schemas/run-record.v1.json.
write_record() {
    if ! jq -n --arg outcome "$1" --argjson code "$2" --arg started "${STARTED}" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "${PWD}" --argjson ci "$(sf_ci_json)" \
        --argjson tool "$(sf_tool_json)" --argjson thresholds "${THRESHOLDS}" \
        --argjson inputs "$(sf_files_json "${SF_INPUTS[@]}")" --argjson results "${RESULTS}" \
        --argjson reports "$(sf_files_json "${@:3}")" --argjson report_only "${REPORT_ONLY}" '{
            schema: "https://github.com/juburr/saf-orb/blob/main/schemas/run-record.v1.json",
            command: "threshold", outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            tool: $tool, inputs: $inputs, thresholds: $thresholds,
            gate: {report_only: $report_only},
            results: [$results[] | {file, profile, outcome, message, compliance}],
            reports: $reports
        }' > "${RECORD}"; then
        echo "WARN: Could not write the run record ${RECORD}." >&2
        return 0
    fi
    echo "Run record: ${RECORD}"
}

# stop MESSAGE...: there is no verdict: writes what reports it can and fails
# the step, whatever report_only says.
stop() {
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    STOP_MESSAGE="$*"
    write_reports error 1 || true
    exit 1
}

sf_tool
echo "Checking $(sf_plural "${#SF_INPUTS[@]}" "HDF file" "HDF files") against these thresholds with SAF CLI ${SF_SAF_VERSION:-(version unknown)}:"
jq -r 'paths(scalars) as $p | "  \($p | map(tostring) | join(".")): \(getpath($p))"' <<< "${THRESHOLDS}"
for path in "${SF_INPUTS[@]}"; do
    if ! sf_hdf "${path}"; then
        stop "${path} is not HDF (Heimdall Data Format) results: a JSON object with a profiles array, each" \
            "profile with a controls array. Convert a tool's results to HDF with the convert command first."
    fi
done

# own_checks COUNTS COMPLIANCE: the first threshold validate threshold skips
# that a file doesn't meet, worded as the SAF CLI words the others, or
# nothing.
OWN_JSON=$(for ((i = 0; i < ${#OWN[@]}; i += 2)); do
    jq -cn --arg key "${OWN[i]}" --argjson value "${OWN[i + 1]}" '{key: $key, value: $value}'
done | jq -cs .)
own_checks() {
    jq -r --argjson counts "$1" --argjson compliance "$2" '
        [.[] | . as $t
            | (if $t.key == "compliance.max" then $compliance else $counts.no_impact.total end) as $got
            | select($got != null)
            | select(($t.key | endswith(".max") and $got > $t.value) or ($t.key | endswith(".min") and $got < $t.value))
            | if $t.key == "compliance.max" then "Overall compliance maximum was not satisfied (\($got)%, at most \($t.value)%)"
              else "\($t.key): Threshold not met. Number of received total no_impact controls (\($got)) is "
                + (if ($t.key | endswith(".max")) then "greater" else "less" end)
                + " than your set threshold for the number of no_impact controls (\($t.value))" end]
        | first // empty' <<< "${OWN_JSON}"
}

n=0
for path in "${SF_INPUTS[@]}"; do
    n=$((n + 1))
    profile=$(sf_top_profiles "${path}" | awk 'NR == 1')
    others=$(sf_top_profiles "${path}" | awk 'NR > 1' | paste -sd, - | sed 's/,/, /g')
    if [[ -n "${others}" ]]; then
        echo "WARN: The SAF CLI checks only ${path}'s first profile, ${profile}, not ${others}." >&2
    fi

    # The counts, from view summary, which reads the first profile as the
    # threshold check does.
    counts=null
    compliance=null
    message=""
    summary="${SF_WORK}/summary-${n}.json"
    status=0
    sf_saf view summary -i "${path}" -f json -o "${summary}" --no-stdout \
        > "${SF_WORK}/summary.log" 2>&1 || status=$?
    if [[ "${status}" -eq 0 ]] && sf_json_is "${summary}" 'type == "array" and length == 1 and (.[0] | type == "object")'; then
        counts=$(jq -c '.[0] | {passed, failed, skipped, no_impact, error}' "${summary}")
        compliance=$(jq -c '.[0].compliance // null' "${summary}")
    else
        outcome=error
        message="saf view summary could not summarize it (exit status ${status})."
        echo "ERROR: ${path}: ${message}" >&2
        sf_tail "${SF_WORK}/summary.log" 20
    fi

    if [[ -z "${message}" ]]; then
        status=0
        sf_saf validate threshold -i "${path}" -T "${SF_WORK}/threshold.json" \
            > "${SF_WORK}/threshold.out" 2> "${SF_WORK}/threshold.err" || status=$?
        failure=$(sed -n 's/^Error: //p' "${SF_WORK}/threshold.err" | awk 'NR == 1')
        if [[ "${status}" -eq 0 ]] && grep -qx 'All validation tests passed' "${SF_WORK}/threshold.out" \
            && ! sf_saf_complained "${SF_WORK}/threshold.err"; then
            outcome=passed
            message="All thresholds met."
            own=$(own_checks "${counts}" "${compliance}")
            if [[ -n "${own}" ]]; then
                outcome=failed
                message=${own}
            fi
        elif [[ "${status}" -eq 1 && -n "${failure}" ]] && ! sf_saf_complained "${SF_WORK}/threshold.err"; then
            outcome=failed
            message=${failure}
        else
            outcome=error
            message="saf validate threshold gave no verdict (exit status ${status})."
            echo "ERROR: ${path}: ${message} It printed:" >&2
            cat "${SF_WORK}/threshold.out" "${SF_WORK}/threshold.err" > "${SF_WORK}/threshold.log"
            sf_tail "${SF_WORK}/threshold.log" 20
        fi
    fi

    RESULTS=$(jq -c --arg file "${path}" --arg sha "$(sf_sha256 "${path}")" --arg profile "${profile}" \
        --arg outcome "${outcome}" --arg message "${message}" --argjson compliance "${compliance}" \
        --argjson counts "${counts}" \
        '. + [{file: $file, sha256: $sha, profile: (if $profile == "" then null else $profile end),
               outcome: $outcome, message: $message, compliance: $compliance, counts: $counts}]' <<< "${RESULTS}")

    echo
    echo "${path} (${profile:-no profile}): ${outcome}"
    if [[ "${counts}" != null ]]; then
        jq -r --argjson compliance "${compliance}" '"  compliance \($compliance)%; "
            + "passed \(.passed.total), failed \(.failed.total) (critical \(.failed.critical), high \(.failed.high), "
            + "medium \(.failed.medium), low \(.failed.low)), not reviewed \(.skipped.total), "
            + "not applicable \(.no_impact.total), error \(.error.total)"' <<< "${counts}"
    fi
    if [[ "${outcome}" != passed ]]; then
        echo "  ${message}"
    fi
done
echo

ERRORS=$(jq '[.[] | select(.outcome == "error")] | length' <<< "${RESULTS}")
FAILED=$(jq '[.[] | select(.outcome == "failed")] | length' <<< "${RESULTS}")
if [[ "${ERRORS}" -gt 0 ]]; then
    stop "The SAF CLI could not check $(sf_plural "${ERRORS}" "file" "files"), so there is no verdict. The reports are in ${SF_OUT}."
fi
if [[ "${FAILED}" -gt 0 ]]; then
    if [[ "${REPORT_ONLY}" == true ]]; then
        write_reports failed-reported 0
    else
        write_reports failed 0
    fi
    sf_gate true "${REPORT_ONLY}" "$(sf_plural "${FAILED}" "file does" "files do") not meet the thresholds."
fi
write_reports passed 0
sf_gate false "${REPORT_ONLY}" "$(sf_plural "${#SF_INPUTS[@]}" "file meets" "files meet") the thresholds."
