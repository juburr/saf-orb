#!/bin/bash
#
# Summarizes HDF results for the summary command with the SAF CLI's view
# summary: per profile, its compliance and how many controls passed, failed,
# were not reviewed, were not applicable or had an error, by severity. The
# Markdown table goes to the log, and on GitHub Actions to the job's summary
# page; the formats asked for go to output_dir as <report_name>.json, .yml
# and .md.
#
# view summary reads the first profile of each file and adds up the files
# whose first profile has the same name. It exits 1 when it can't read a
# file, but writes its output with a warning when it can't, so the step
# checks every file it asked for.
#
# Parameters (CircleCI passes them as PARAM_* variables):
#   PARAM_INPUT, PARAM_FORMATS, PARAM_STEP_SUMMARY, PARAM_OUTPUT_DIR,
#   PARAM_REPORT_NAME

set -euo pipefail

if [[ -z "${SCRIPT_SAF_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_SAF_LIB is not set; run this script through the orb's summary command." >&2
    exit 1
fi
eval "${SCRIPT_SAF_LIB}"

# --- Reports ---
# Checked and cleared before anything else, so a run that stops never leaves
# an earlier run's summary to be stored as its own; never an HDF file it
# reads, though.
REPORT_NAME=${PARAM_REPORT_NAME}
sf_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
sf_inputs input "${PARAM_INPUT}"
sf_reports_apart "${SF_BASE}.json" "${SF_BASE}.yml" "${SF_BASE}.md"
rm -f "${SF_BASE}.json" "${SF_BASE}.yml" "${SF_BASE}.md"
sf_inputs_check

STEP_SUMMARY=$(sf_bool step_summary "${PARAM_STEP_SUMMARY}")
sf_list formats "${PARAM_FORMATS}"
FORMATS=()
for format in ${SF_LIST[@]+"${SF_LIST[@]}"}; do
    case "${format}" in
        json | yaml | markdown) FORMATS+=("${format}") ;;
        *)
            echo "ERROR: formats takes json, yaml and markdown, not '${format}'." >&2
            exit 2
            ;;
    esac
done

sf_require_jq
SF_WORK=$(mktemp -d)
trap 'rm -rf "${SF_WORK}"' EXIT
for path in "${SF_INPUTS[@]}"; do
    sf_require_hdf "${path}"
    others=$(sf_top_profiles "${path}" | awk 'NR > 1' | paste -sd, - | sed 's/,/, /g')
    if [[ -n "${others}" ]]; then
        echo "WARN: The summary counts only ${path}'s first profile, $(sf_top_profiles "${path}" | awk 'NR == 1'), not ${others}." >&2
    fi
done
sf_tool

# summarize FORMAT FILE: writes the summary of every input in FORMAT to FILE,
# or stops the step.
summarize() {
    local status=0
    sf_saf view summary -i "${SF_INPUTS[@]}" -f "$1" -o "$2" --no-stdout > "${SF_WORK}/summary.log" 2>&1 || status=$?
    if [[ "${status}" -ne 0 || ! -s "$2" ]] || sf_saf_complained "${SF_WORK}/summary.log"; then
        echo "ERROR: saf view summary could not summarize the files (exit status ${status}). It printed:" >&2
        sf_tail "${SF_WORK}/summary.log"
        exit 1
    fi
}

echo "Summarizing $(sf_plural "${#SF_INPUTS[@]}" "HDF file" "HDF files") with SAF CLI ${SF_SAF_VERSION:-(version unknown)}."
summarize markdown "${SF_WORK}/summary.md"
summarize json "${SF_WORK}/summary.json"
if ! sf_json_is "${SF_WORK}/summary.json" 'type == "array" and length > 0 and all(.[]; type == "object" and has("profileName"))'; then
    echo "ERROR: saf view summary wrote no summary of any profile." >&2
    exit 1
fi
echo
cat "${SF_WORK}/summary.md"
echo
for format in ${FORMATS[@]+"${FORMATS[@]}"}; do
    case "${format}" in
        json) cp "${SF_WORK}/summary.json" "${SF_BASE}.json" ;;
        markdown) cp "${SF_WORK}/summary.md" "${SF_BASE}.md" ;;
        yaml)
            summarize yaml "${SF_WORK}/summary.yml"
            cp "${SF_WORK}/summary.yml" "${SF_BASE}.yml"
            ;;
    esac
done
if [[ ${#FORMATS[@]} -gt 0 ]]; then
    echo "Wrote the summary to ${SF_OUT} as ${REPORT_NAME}.{$(printf '%s\n' "${FORMATS[@]}" \
        | sed 's/^yaml$/yml/; s/^markdown$/md/' | paste -sd, -)}."
fi
if [[ "${STEP_SUMMARY}" == true && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '### SAF CLI summary\n\n'
        cat "${SF_WORK}/summary.md"
        printf '\n\n'
    } >> "${GITHUB_STEP_SUMMARY}"
    echo "Added the summary to the GitHub Actions job summary."
fi
