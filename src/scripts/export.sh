#!/bin/bash
#
# Exports HDF results for the export command with one of the SAF CLI's
# hdf2<format> converters: a STIG Viewer checklist (ckl), XCCDF results
# (xccdf), CSV (csv), an HTML report (html) or a CAAT spreadsheet (caat).
#
# ckl, xccdf and csv write one file per HDF file, named after it
# (results.json gives results.ckl), or after report_name when there is one
# HDF file and report_name is set. html and caat put every HDF file in one
# file, <report_name>.html or .xlsx (default: the first HDF file's name).
#
# The SAF CLI's converters exit 0 whatever goes wrong, printing a warning
# instead, so the step fails unless it printed none and each file it wrote
# looks like what it should be: a CHECKLIST or Benchmark XML document, a CSV
# header, an HTML document, or an XLSX (zip) file.
#
# Parameters (CircleCI passes them as PARAM_* variables):
#   PARAM_INPUT, PARAM_FORMAT, PARAM_EXTRA_ARGS, PARAM_OUTPUT_DIR,
#   PARAM_REPORT_NAME

set -euo pipefail

if [[ -z "${SCRIPT_SAF_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_SAF_LIB is not set; run this script through the orb's export command." >&2
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

FORMAT=$(sf_subst "${PARAM_FORMAT}")
case "${FORMAT}" in
    ckl) EXT=ckl COMBINED=false ;;
    xccdf) EXT=xml COMBINED=false ;;
    csv) EXT=csv COMBINED=false ;;
    html) EXT=html COMBINED=true ;;
    caat) EXT=xlsx COMBINED=true ;;
    *) usage "format must be ckl, xccdf, csv, html or caat, not '${FORMAT}'." ;;
esac
REPORT_NAME=${PARAM_REPORT_NAME}
if [[ -n "${REPORT_NAME}" ]]; then
    sf_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
else
    # Checks output_dir alone: the names come from the HDF files.
    sf_output "${PARAM_OUTPUT_DIR}" x
fi
sf_words extra_args "$(sf_subst "${PARAM_EXTRA_ARGS}")"
EXTRA_ARGS=(${SF_WORDS[@]+"${SF_WORDS[@]}"})
sf_inputs input "${PARAM_INPUT}"

# extra_args: the format's own options, which hdf2<format> takes; the input
# and output are the command's. A file it reads is made absolute, since the
# SAF CLI runs in a directory of its own.
ARGS=()
i=0
while ((i < ${#EXTRA_ARGS[@]})); do
    word=${EXTRA_ARGS[i]}
    option=${word%%=*}
    kind=""
    case "${FORMAT}:${option}" in
        ckl:-m | ckl:--metadata) kind=path ;;
        ckl:--profilename | ckl:--profiletitle | ckl:--version | ckl:--releasenumber | ckl:--releasedate \
            | ckl:--marking | ckl:-H | ckl:--hostname | ckl:-I | ckl:--ip | ckl:-M | ckl:--mac | ckl:-F | ckl:--fqdn \
            | ckl:--targetcomment | ckl:--role | ckl:--assettype | ckl:--techarea | ckl:--stigguid | ckl:--targetkey \
            | ckl:--webdbsite | ckl:--webdbinstance | ckl:--vulidmapping | csv:-f | csv:--fields | html:-t | html:--type)
            kind=value
            ;;
        ckl:--webordatabase | csv:-t | csv:--noTruncate) kind=flag ;;
        *)
            usage "extra_args: ${word} is not an option export passes to hdf2${FORMAT}." \
                "input and the output's name are parameters; see the README for each format's options."
            ;;
    esac
    if [[ "${kind}" == flag ]]; then
        [[ "${word}" != *=* ]] || usage "extra_args: ${option} takes no value."
        ARGS+=("${option}")
        i=$((i + 1))
        continue
    fi
    if [[ "${word}" == *=* ]]; then
        value=${word#*=}
    else
        ((i + 1 < ${#EXTRA_ARGS[@]})) || usage "extra_args: ${option} needs a value."
        i=$((i + 1))
        value=${EXTRA_ARGS[i]}
    fi
    if [[ "${kind}" == path ]]; then
        [[ -f "${value}" && -r "${value}" ]] || usage "extra_args: ${option} ${value} is not a readable file."
        value=$(sf_abs "${value}")
    fi
    ARGS+=("${option}" "${value}")
    i=$((i + 1))
done

# What to write: one run per HDF file, or one for them all.
base_of() {
    local name=${1##*/}
    name=${name%.json}
    sf_safe_name "${name}"
}
RUNS=()
OUTPUTS=()
if [[ "${COMBINED}" == true ]]; then
    RUNS=("all")
    OUTPUTS=("${SF_OUT%/}/${REPORT_NAME:-$(base_of "${SF_INPUTS[0]}")}.${EXT}")
else
    for path in "${SF_INPUTS[@]}"; do
        RUNS+=("${path}")
        if [[ -n "${REPORT_NAME}" && ${#SF_INPUTS[@]} -eq 1 ]]; then
            OUTPUTS+=("${SF_BASE}.${EXT}")
        elif [[ -n "${REPORT_NAME}" ]]; then
            OUTPUTS+=("${SF_BASE}-$(base_of "${path}").${EXT}")
        else
            OUTPUTS+=("${SF_OUT%/}/$(base_of "${path}").${EXT}")
        fi
    done
fi
duplicates=$(printf '%s\n' "${OUTPUTS[@]}" | sort | uniq -d)
if [[ -n "${duplicates}" ]]; then
    usage "Two HDF files would be exported to the same file: ${duplicates//$'\n'/ }" \
        "Give them different names, or set report_name."
fi
for out in "${OUTPUTS[@]}"; do
    for path in "${SF_INPUTS[@]}"; do
        if [[ "${out}" -ef "${path}" ]]; then
            usage "The export ${out} would replace the HDF file it is made from."
        fi
    done
done
# Cleared before anything runs, so a failed export never leaves an earlier
# one to be stored as its own.
rm -f "${OUTPUTS[@]}"

sf_require_jq
SF_WORK=$(mktemp -d)
trap 'rm -rf "${SF_WORK}"' EXIT
for path in "${SF_INPUTS[@]}"; do
    sf_require_hdf "${path}"
done
sf_tool

# looks_right FILE: whether FILE looks like the format's output.
looks_right() {
    local head tail
    head=$(head -c 4096 "$1" | tr -d '\0')
    tail=$(tail -c 256 "$1" | tr -d '\0' | tr -d '[:space:]')
    case "${FORMAT}" in
        ckl) [[ "${head}" == *"<CHECKLIST>"* && "${tail}" == *"</CHECKLIST>" ]] ;;
        xccdf) [[ "${head}" == *"<Benchmark"* && "${tail}" == *"</Benchmark>" ]] ;;
        csv) [[ -s "$1" && "$(head -n 1 "$1")" == *,* ]] ;;
        html) [[ "${head}" == *"<html"* && "${tail}" == *"</html>" ]] ;;
        caat) [[ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" == 504b0304 ]] ;;
    esac
}

echo "Exporting $(sf_plural "${#SF_INPUTS[@]}" "HDF file" "HDF files") as ${FORMAT} with SAF CLI ${SF_SAF_VERSION:-(version unknown)}."
for ((n = 0; n < ${#RUNS[@]}; n++)); do
    out=${OUTPUTS[n]}
    staged="${SF_WORK}/out/${out##*/}"
    mkdir -p "${SF_WORK}/out"
    rm -f "${staged}"
    if [[ "${RUNS[n]}" == all ]]; then
        COMMAND=(convert "hdf2${FORMAT}" -i "${SF_INPUTS[@]}" -o "${staged}" ${ARGS[@]+"${ARGS[@]}"})
    else
        COMMAND=(convert "hdf2${FORMAT}" -i "${RUNS[n]}" -o "${staged}" ${ARGS[@]+"${ARGS[@]}"})
    fi
    printf '+ saf'
    printf ' %q' "${COMMAND[@]}"
    printf '\n'
    status=0
    sf_saf "${COMMAND[@]}" > "${SF_WORK}/export.log" 2>&1 || status=$?
    if [[ "${status}" -ne 0 || ! -f "${staged}" ]] || sf_saf_complained "${SF_WORK}/export.log" \
        || grep -q '^Error' "${SF_WORK}/export.log"; then
        echo "ERROR: saf convert hdf2${FORMAT} could not export ${RUNS[n]/#all/the files} (exit status ${status}). It printed:" >&2
        sf_tail "${SF_WORK}/export.log"
        exit 1
    fi
    if ! looks_right "${staged}"; then
        echo "ERROR: saf convert hdf2${FORMAT} wrote a file that is not ${FORMAT} output." >&2
        exit 1
    fi
    mv "${staged}" "${out}"
    echo "  ${out}"
done
