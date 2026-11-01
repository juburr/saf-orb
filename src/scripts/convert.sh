#!/bin/bash
#
# Converts a security tool's results to HDF (the Heimdall Data Format) for
# the convert command, with the SAF CLI's <from>2hdf converter, then checks
# that it wrote HDF and exports the files' paths.
#
# The SAF CLI's converters exit 0 whatever goes wrong, printing a warning
# instead, and some write several files (one per host or project, or a
# directory of them). So the converter writes into this step's private work
# directory, and the step fails unless the SAF CLI printed no warning and
# every file it wrote is HDF. Those files are then moved to output_dir:
# <report_name>.json when there is one, <report_name>-<name>.json for each
# when there are several. <report_name>.files lists them, so the next run
# with the same report_name removes them first.
#
# Parameters (CircleCI passes them as PARAM_* variables):
#   PARAM_FROM          the converter: the part of its name before "2hdf"
#   PARAM_INPUT         the tool's results file
#   PARAM_INCLUDE_RAW   add the tool's results to the HDF (-w)
#   PARAM_EXTRA_ARGS    the converter's own options
#   PARAM_OUTPUT_DIR    where the HDF files go (not expanded)
#   PARAM_REPORT_NAME   what their names start with (empty: from)
#   PARAM_HDF_ENV_VAR   the variable to export their paths in, one per line

set -euo pipefail

if [[ -z "${SCRIPT_SAF_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_SAF_LIB is not set; run this script through the orb's convert command." >&2
    exit 1
fi
eval "${SCRIPT_SAF_LIB}"

# usage MESSAGE...: stops the step on a parameter that can't work, before
# anything runs.
usage() {
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    exit 2
}

FROM=$(sf_subst "${PARAM_FROM}")

# The converters this command runs, by how they write their results:
#   file    one HDF file, at -o
#   files   one HDF file, or one per host or project, named after -o
#   dir     a directory of HDF files, at -o
# raw marks those with -w (--includeRaw). Left out: those that read a
# service rather than a file (aws_config, ionchannel, msft_secure, sonarqube,
# splunk), and trufflehog, whose HDF holds every secret TruffleHog found in
# full (Raw, RawV2). For TruffleHog, convert its SARIF with from: sarif.
case "${FROM}" in
    anchoregrype | burpsuite | checkov | ckl | cyclonedx_sbom | dbprotect | fortify | gosec | jfrog_xray \
        | netsparker | neuvector | nikto | sarif | scoutsuite | twistlock | xccdf_results | zap)
        LAYOUT=file RAW=true ;;
    dependency_track | veracode) LAYOUT=file RAW=false ;;
    nessus) LAYOUT=files RAW=true ;;
    snyk) LAYOUT=files RAW=false ;;
    asff | conveyor | prisma | prowler | trivy) LAYOUT=dir RAW=false ;;
    trufflehog)
        usage "from: trufflehog is not supported: the SAF CLI's trufflehog2hdf copies every secret TruffleHog found," \
            "in full, into the HDF. Convert TruffleHog's SARIF output instead, with from: sarif."
        ;;
    aws_config | ionchannel | msft_secure | sonarqube | splunk)
        usage "from: ${FROM} is not supported: that converter reads a service, not a file, and takes credentials on" \
            "its command line."
        ;;
    *) usage "from must name one of the SAF CLI's file converters, such as anchoregrype or sarif, not '${FROM}'." ;;
esac

INPUT=$(sf_path "$(sf_subst "${PARAM_INPUT}")")
INPUT_ERROR=""
if [[ -z "${INPUT}" ]]; then
    INPUT_ERROR="input must name the file of ${FROM} results to convert."
elif [[ ! -f "${INPUT}" || ! -r "${INPUT}" ]]; then
    INPUT_ERROR="input ${INPUT} is not a readable file."
fi
if [[ -n "${INPUT}" ]]; then
    INPUT=$(sf_abs "${INPUT}")
fi

# extra_args: only the converter's own options, since the command sets the
# input, the output and -w itself. A path the SAF CLI reads is made absolute,
# since it runs in a directory of its own. Read before the reports are
# cleared, so a file an option names is never cleared; the first problem is
# kept in EXTRA_ERROR, so the reports are cleared even so.
# A value that can't be split is reported by sf_words after the clearing.
EXTRA_VALUE=$(sf_subst "${PARAM_EXTRA_ARGS}")
EXTRA_ARGS=()
SPLIT_STATUS=0
split_shell_words "${EXTRA_VALUE}" || SPLIT_STATUS=$?
if [[ "${SPLIT_STATUS}" -eq 0 ]]; then
    EXTRA_ARGS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
fi
ARGS=()
AUX_INPUTS=()
EXTRA_ERROR=()
NAMED=false
i=0
while ((i < ${#EXTRA_ARGS[@]})); do
    word=${EXTRA_ARGS[i]}
    option=${word%%=*}
    value=""
    if [[ "${word}" == *=* ]]; then
        value=${word#*=}
    fi
    case "${FROM}:${option}" in
        zap:-n | zap:--name) kind=value NAMED=true ;;
        nessus:-p | nessus:--parser) kind=value ;;
        asff:-H | asff:--securityHub) kind=path ;;
        *)
            EXTRA_ERROR=("extra_args: ${word} is not an option convert passes to ${FROM}2hdf."
                "It takes zap's --name, nessus's --parser and asff's --securityHub; input, output and include_raw are parameters.")
            break
            ;;
    esac
    if [[ "${word}" != *=* ]]; then
        if ((i + 1 >= ${#EXTRA_ARGS[@]})); then
            EXTRA_ERROR=("extra_args: ${option} needs a value.")
            break
        fi
        i=$((i + 1))
        value=${EXTRA_ARGS[i]}
    fi
    if [[ "${kind}" == path ]]; then
        value=$(sf_path "${value}")
        if [[ ! -f "${value}" || ! -r "${value}" ]]; then
            EXTRA_ERROR=("extra_args: ${option} ${value} is not a readable file.")
            break
        fi
        value=$(sf_abs "${value}")
        AUX_INPUTS+=("${value}")
    fi
    ARGS+=("${option}" "${value}")
    i=$((i + 1))
done

# --- Reports ---
# Checked and cleared before the converter runs, so a failed run never
# leaves an earlier run's HDF to be taken for its own; never the input,
# though. Neither is expanded: the step that stores the files reads them as
# given.
REPORT_NAME=${PARAM_REPORT_NAME:-${FROM}}
sf_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
MANIFEST="${SF_BASE}.files"
OLD=("${SF_BASE}.json" "${MANIFEST}")
if [[ -f "${MANIFEST}" ]]; then
    while IFS= read -r old; do
        case "${old}" in
            "${SF_BASE}"-*.json) OLD+=("${old}") ;;
        esac
    done < "${MANIFEST}"
fi
# shellcheck disable=SC2034 # read by sf_reports_apart
SF_INPUTS=(${INPUT:+"${INPUT}"})
# shellcheck disable=SC2034 # read by sf_reports_apart
SF_OTHER_INPUTS=(${AUX_INPUTS[@]+"${AUX_INPUTS[@]}"})
sf_reports_apart "${OLD[@]}"
rm -f "${OLD[@]}"
if [[ -n "${INPUT_ERROR}" ]]; then
    usage "${INPUT_ERROR}"
fi
if [[ "${SPLIT_STATUS}" -ne 0 ]]; then
    sf_words extra_args "${EXTRA_VALUE}"
fi
if [[ ${#EXTRA_ERROR[@]} -gt 0 ]]; then
    usage "${EXTRA_ERROR[@]}"
fi

INCLUDE_RAW=$(sf_bool include_raw "${PARAM_INCLUDE_RAW}")
HDF_ENV_VAR=$(sf_subst "${PARAM_HDF_ENV_VAR}")

# --- Parameters ---
if [[ "${INCLUDE_RAW}" == true && "${RAW}" == false ]]; then
    usage "include_raw is not available for from: ${FROM}: its converter has no -w option."
fi
if [[ -n "${HDF_ENV_VAR}" ]] && ! sf_match "${HDF_ENV_VAR}" '^[A-Za-z_][A-Za-z0-9_]*$'; then
    usage "hdf_env_var must name an environment variable, not '${HDF_ENV_VAR}'."
fi
if [[ "${FROM}" == zap && "${NAMED}" == false ]]; then
    usage "from: zap needs the scanned site's name: extra_args: --name https://example.com"
fi

if [[ "${INCLUDE_RAW}" == true ]]; then
    ARGS+=(-w)
fi

sf_require_jq
SF_WORK=$(mktemp -d)
trap 'rm -rf "${SF_WORK}"' EXIT
sf_tool
mkdir -p "${SF_WORK}/out"
case "${LAYOUT}" in
    dir) OUT="${SF_WORK}/out/${REPORT_NAME}" ;;
    *) OUT="${SF_WORK}/out/${REPORT_NAME}.json" ;;
esac

echo "Converting ${INPUT} from ${FROM} to HDF with SAF CLI ${SF_SAF_VERSION:-(version unknown)}."
COMMAND=(convert "${FROM}2hdf" -i "${INPUT}" -o "${OUT}" ${ARGS[@]+"${ARGS[@]}"})
printf '+ saf'
printf ' %q' "${COMMAND[@]}"
printf '\n'
STATUS=0
sf_saf "${COMMAND[@]}" > "${SF_WORK}/stdout.log" 2> "${SF_WORK}/stderr.log" || STATUS=$?
cat "${SF_WORK}/stdout.log"

# fail MESSAGE: shows what the SAF CLI printed and stops the step.
fail() {
    echo "ERROR: $1" >&2
    if [[ -s "${SF_WORK}/stderr.log" ]]; then
        echo "  The SAF CLI printed:" >&2
        sf_tail "${SF_WORK}/stderr.log"
    fi
    if [[ -s "${SF_WORK}/run/saf-cli.log" ]]; then
        echo "  Its log (saf-cli.log) ends:" >&2
        sf_tail "${SF_WORK}/run/saf-cli.log" 20
    fi
    exit 1
}

if [[ "${STATUS}" -ne 0 ]]; then
    fail "saf convert ${FROM}2hdf exited with status ${STATUS}."
fi
if sf_saf_complained "${SF_WORK}/stderr.log"; then
    fail "saf convert ${FROM}2hdf could not convert ${INPUT} (it exits 0 even so)."
fi

# What it wrote: every regular file under out, and nothing else.
FILES=()
while IFS= read -r -d '' path; do
    FILES+=("${path}")
done < <(find "${SF_WORK}/out" -mindepth 1 -type f -print0 | LC_ALL=C sort -z)
if [[ -n "$(find "${SF_WORK}/out" -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    fail "saf convert ${FROM}2hdf wrote something other than files."
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
    fail "saf convert ${FROM}2hdf wrote no HDF file."
fi
for path in "${FILES[@]}"; do
    if [[ "${path}" != *.json ]]; then
        fail "saf convert ${FROM}2hdf wrote ${path#"${SF_WORK}/out/"}, which is not a .json file."
    fi
    if ! sf_hdf "${path}"; then
        fail "saf convert ${FROM}2hdf wrote ${path#"${SF_WORK}/out/"}, which is not HDF results."
    fi
done

# Their names in output_dir: <report_name>.json for one file, else
# <report_name>-<name>.json, the name being what the SAF CLI called the file
# without the report name it started with, in characters safe in a name.
DEST=()
if [[ ${#FILES[@]} -eq 1 ]]; then
    DEST=("${SF_BASE}.json")
else
    for path in "${FILES[@]}"; do
        name=${path##*/}
        name=${name%.json}
        name=${name#"${REPORT_NAME}"-}
        name=$(sf_safe_name "${name}")
        DEST+=("${SF_BASE}-${name:-hdf}.json")
    done
    duplicates=$(printf '%s\n' "${DEST[@]}" | sort | uniq -d)
    if [[ -n "${duplicates}" ]]; then
        fail "saf convert ${FROM}2hdf wrote files whose names collide once made safe: ${duplicates//$'\n'/ }"
    fi
fi
: > "${MANIFEST}"
for ((n = 0; n < ${#FILES[@]}; n++)); do
    if [[ -e "${DEST[n]}" || -L "${DEST[n]}" ]]; then
        fail "${DEST[n]} already exists; convert won't replace a file an earlier step wrote. Choose another report_name."
    fi
    mv "${FILES[n]}" "${DEST[n]}"
    printf '%s\n' "${DEST[n]}" >> "${MANIFEST}"
done

echo "Wrote $(sf_plural "${#DEST[@]}" "HDF file" "HDF files"):"
for path in "${DEST[@]}"; do
    jq -r --arg path "${path}" '"  \($path): \(.profiles | length) profile(s), \([.profiles[].controls | length] | add) control(s)"' "${path}"
done
if [[ -n "${HDF_ENV_VAR}" ]]; then
    sf_export "${HDF_ENV_VAR}" "$(printf '%s\n' "${DEST[@]}")"
    echo "Exported ${HDF_ENV_VAR} with their paths, one per line."
fi
