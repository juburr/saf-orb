#!/bin/bash

# Shared helpers for the saf-orb commands. Each command passes this file to
# its step as SCRIPT_SAF_LIB, and its script evals it after set -euo pipefail,
# so it only defines functions and variables. The helpers keep their state in
# SF_ variables, since the SAF CLI reads SAF_ ones.
#
# Most SAF CLI commands exit 0 whatever goes wrong: they print a warning
# instead (oclif's " ›   Error: ..." lines on stderr). So the scripts run the
# SAF CLI in a private work directory, never trust its exit code alone, and
# check what it wrote.

# sf_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
sf_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# sf_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
sf_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# sf_words PARAMETER VALUE: sets SF_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
sf_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    SF_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# sf_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
sf_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# sf_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
sf_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# sf_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# SF_OUT to DIR and SF_BASE to the path every report of this run starts with.
sf_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! sf_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    SF_OUT=${1%/}
    SF_OUT=${SF_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    SF_BASE="${SF_OUT%/}/$2"
}

# sf_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
sf_uint() {
    if ! sf_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# sf_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
sf_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# sf_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
sf_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${SF_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${SF_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# sf_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
sf_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# sf_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed.
sf_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}

# sf_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
sf_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# sf_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
sf_env_var_name() {
    if ! sf_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# sf_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
sf_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# sf_sha256 FILE: prints FILE's SHA-256.
sf_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# sf_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
sf_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# sf_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
sf_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# sf_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
sf_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# sf_list PARAMETER VALUE: sets SF_LIST to VALUE, with environment variables
# expanded, split on commas, spaces and newlines.
sf_list() {
    local value
    SF_LIST=()
    value=$(sf_subst "$2")
    value=${value//,/ }
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -d '' -a SF_LIST <<< "${value//$'\n'/ }" || true
}

# sf_tool: sets SF_SAF to the saf on the PATH, SF_SAF_VERSION to the version
# it reports, and SF_INSTALL_JSON to the install record of this orb's install
# command beside it (null for a SAF CLI installed otherwise), or stops the
# step. Needs SF_WORK.
sf_tool() {
    local root
    if ! SF_SAF=$(command -v saf 2> /dev/null) || [[ -z "${SF_SAF}" ]]; then
        echo "ERROR: saf is not on the PATH. Run this orb's install command in an earlier step." >&2
        exit 1
    fi
    # oclif prints "@mitre/saf/1.7.0 linux-x64 node-v22.23.2".
    SF_SAF_VERSION=$(sf_saf --version 2> /dev/null | awk '{ sub(/^@mitre\/saf\//, "", $1); print $1; exit }') \
        || SF_SAF_VERSION=""
    root=${SF_SAF%/bin/saf}
    SF_INSTALL_JSON=null
    if [[ "${root}" != "${SF_SAF}" && -f "${root}/.saf-orb" ]]; then
        SF_INSTALL_JSON=$(jq -c 'select(type == "object")' "${root}/.saf-orb" 2> /dev/null) || SF_INSTALL_JSON=""
        # shellcheck disable=SC2034 # read by the script that evals this file
        SF_INSTALL_JSON=${SF_INSTALL_JSON:-null}
    fi
}

# sf_saf ARG...: runs the SAF CLI in SF_WORK/run, a directory of its own, so
# the log file it writes (saf-cli.log) and anything else it leaves in its
# working directory stay out of the checkout. SAF_SKIP_NEW_VERSION_CHECK
# stops its daily check of npm for a newer release.
sf_saf() {
    mkdir -p "${SF_WORK:?}/run"
    (cd "${SF_WORK}/run" && SAF_SKIP_NEW_VERSION_CHECK=true "${SF_SAF}" "$@")
}

# sf_saf_complained FILE: whether FILE, the SAF CLI's stderr, holds a warning
# or error oclif printed: lines marked with "›". Most SAF CLI commands print
# one in place of failing, and exit 0.
sf_saf_complained() {
    grep -q '›' "$1"
}

# sf_abs PATH: prints PATH made absolute against the working directory,
# without following symbolic links.
sf_abs() {
    if [[ "$1" == /* ]]; then
        printf '%s\n' "$1"
    else
        printf '%s/%s\n' "${PWD%/}" "${1#./}"
    fi
}

# sf_inputs PARAMETER VALUE: sets SF_INPUTS to the absolute paths of the HDF
# files VALUE names: paths or globs, separated by commas, spaces or newlines,
# with environment variables expanded. An empty VALUE takes the files the
# last convert step exported in SAF_HDF_FILES, one per line. A leading ~ is
# HOME. Each must be a readable file, and a glob must match something; the
# first problem goes in SF_INPUTS_ERROR rather than stopping the step, so a
# script can clear an earlier run's reports (but none of the files found)
# before sf_inputs_check stops it.
sf_inputs() {
    local item path matched seen=$'\n'
    SF_INPUTS=()
    SF_INPUTS_ERROR=""
    if [[ -z "$2" ]]; then
        if [[ -z "${SAF_HDF_FILES:-}" ]]; then
            SF_INPUTS_ERROR="${1} is empty, and no convert step exported SAF_HDF_FILES. Name the HDF files in ${1}."
            return 0
        fi
        while IFS= read -r path; do
            if [[ -n "${path}" && "${seen}" != *$'\n'"${path}"$'\n'* ]]; then
                SF_INPUTS+=("${path}")
                seen+="${path}"$'\n'
            fi
        done <<< "${SAF_HDF_FILES}"
    else
        sf_list "$1" "$2"
        for item in ${SF_LIST[@]+"${SF_LIST[@]}"}; do
            item=$(sf_path "${item}")
            matched=false
            while IFS= read -r path; do
                [[ -n "${path}" ]] || continue
                matched=true
                path=$(sf_abs "${path}")
                if [[ "${seen}" != *$'\n'"${path}"$'\n'* ]]; then
                    SF_INPUTS+=("${path}")
                    seen+="${path}"$'\n'
                fi
            done < <(compgen -G "${item}" || true)
            if [[ "${matched}" == false && -z "${SF_INPUTS_ERROR}" ]]; then
                SF_INPUTS_ERROR="${1}: ${item} matches no file."
            fi
        done
    fi
    if [[ ${#SF_INPUTS[@]} -eq 0 && -z "${SF_INPUTS_ERROR}" ]]; then
        SF_INPUTS_ERROR="${1} names no file."
    fi
    for path in ${SF_INPUTS[@]+"${SF_INPUTS[@]}"}; do
        if [[ (! -f "${path}" || ! -r "${path}") && -z "${SF_INPUTS_ERROR}" ]]; then
            SF_INPUTS_ERROR="${path} is not a readable file."
        fi
    done
}

# sf_inputs_check: stops the step on the problem sf_inputs found, if any.
sf_inputs_check() {
    if [[ -n "${SF_INPUTS_ERROR:-}" ]]; then
        echo "ERROR: ${SF_INPUTS_ERROR}" >&2
        exit 1
    fi
}

# sf_hdf FILE: whether FILE holds HDF results: a JSON object whose profiles
# are an array of objects, each with an array of controls.
sf_hdf() {
    sf_json_is "$1" 'type == "object" and (.profiles | type == "array") and (.profiles | length > 0)
        and all(.profiles[]; type == "object" and (.controls | type == "array"))'
}

# sf_require_hdf FILE: stops the step unless FILE holds HDF results.
sf_require_hdf() {
    if ! sf_hdf "$1"; then
        echo "ERROR: $1 is not HDF (Heimdall Data Format) results: a JSON object with a profiles array, each" >&2
        echo "  profile with a controls array. Convert a tool's results to HDF with the convert command first." >&2
        exit 1
    fi
}

# sf_top_profiles FILE: prints the names of FILE's profiles that no other
# profile in it depends on (no parent_profile), one per line. The SAF CLI's
# threshold and summary read only the first profile.
sf_top_profiles() {
    jq -r '.profiles[] | select((.parent_profile // "") == "") | .name // "(unnamed)"' "$1"
}

# sf_tool_json: the SAF CLI that ran, for run records.
sf_tool_json() {
    jq -cn --arg path "${SF_SAF:-}" --arg version "${SF_SAF_VERSION:-}" --argjson install "${SF_INSTALL_JSON:-null}" \
        'if $path == "" then null else {name: "saf", path: $path, version: $version, install: $install} end'
}

# sf_files_json PATH...: the files as a JSON array of {path, sha256}.
sf_files_json() {
    local path out="[]"
    for path in "$@"; do
        if [[ -f "${path}" ]]; then
            out=$(jq -c --arg path "${path}" --arg sha "$(sf_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${out}")
        fi
    done
    printf '%s\n' "${out}"
}

# sf_safe_name NAME: prints NAME with every character but ASCII letters,
# digits, ".", "_" and "-" replaced by "_", for a file name.
sf_safe_name() {
    local LC_ALL=C
    printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"
}

# sf_path VALUE: VALUE with a leading ~ (alone, or before a /) replaced by
# HOME, as a shell would expand it: CircleCI's env subst expands variables,
# not ~, and configs often write paths as ~/....
sf_path() {
    # shellcheck disable=SC2088 # the literal ~ is what is matched
    case "$1" in
        "~") printf '%s\n' "${HOME}" ;;
        "~/"*) printf '%s/%s\n' "${HOME%/}" "${1:2}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# sf_reports_apart PATH...: stops the step (exit 2) when a file this step
# would clear and write is one of the files it reads, which clearing it
# would delete: the HDF files (SF_INPUTS) and any other (SF_OTHER_INPUTS,
# such as a threshold template).
sf_reports_apart() {
    local report input
    for report in "$@"; do
        [[ -e "${report}" ]] || continue
        for input in ${SF_INPUTS[@]+"${SF_INPUTS[@]}"} ${SF_OTHER_INPUTS[@]+"${SF_OTHER_INPUTS[@]}"}; do
            if [[ "${report}" -ef "${input}" ]]; then
                echo "ERROR: ${report}, which this step writes, is ${input}, which it reads." >&2
                echo "  Choose another report_name or output_dir." >&2
                exit 2
            fi
        done
    done
}
