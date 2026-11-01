#!/bin/bash
#
# Uploads HDF results to a Heimdall server for the upload_heimdall command,
# through its API (POST /evaluations), with an API key. The SAF CLI has no
# command for it, so this step uses curl.
#
# Heimdall stores whatever it is sent, so every file is checked to be HDF
# first, and the server is asked (GET /server) whether it takes API keys
# before the key is sent. Each file is one evaluation, uploaded once: an
# upload is never retried, since a retry after a lost answer would store the
# results twice. <report_name>.json lists the evaluations, and their URLs are
# exported for later steps.
#
# The key is read from the variable api_key names, never from a parameter,
# and reaches curl in a header file in this step's private work directory,
# never on its command line.
#
# Parameters (CircleCI passes them as PARAM_* variables):
#   PARAM_URL, PARAM_API_KEY, PARAM_INPUT, PARAM_PUBLIC,
#   PARAM_EVALUATION_TAGS, PARAM_GROUPS, PARAM_TIMEOUT,
#   PARAM_EVALUATION_URLS_ENV_VAR, PARAM_OUTPUT_DIR, PARAM_REPORT_NAME

set -euo pipefail
# The API key passes through variables: never trace them.
set +o xtrace

if [[ -z "${SCRIPT_SAF_LIB:-}" ]]; then
    echo "ERROR: SCRIPT_SAF_LIB is not set; run this script through the orb's upload_heimdall command." >&2
    exit 1
fi
eval "${SCRIPT_SAF_LIB}"

# usage MESSAGE...: stops the step on a parameter that can't work, before
# anything is sent.
usage() {
    printf 'ERROR: %s\n' "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf '  %s\n' "${@:2}" >&2
    fi
    exit 2
}

# The list of evaluations is cleared before anything is sent, so a failed
# run never leaves an earlier one's; never an HDF file it reads, though.
REPORT_NAME=${PARAM_REPORT_NAME}
sf_output "${PARAM_OUTPUT_DIR}" "${REPORT_NAME}"
REPORT="${SF_BASE}.json"
sf_inputs input "${PARAM_INPUT}"
sf_reports_apart "${REPORT}"
rm -f "${REPORT}"
sf_inputs_check

URL=$(sf_subst "${PARAM_URL}")
URL=${URL%/}
API_KEY_VAR=$(sf_subst "${PARAM_API_KEY}")
PUBLIC=$(sf_bool public "${PARAM_PUBLIC}")
TAGS=$(sf_subst "${PARAM_EVALUATION_TAGS}")
TIMEOUT=$(sf_subst "${PARAM_TIMEOUT}")
URLS_ENV_VAR=$(sf_subst "${PARAM_EVALUATION_URLS_ENV_VAR}")
sf_list groups "${PARAM_GROUPS}"
GROUPS_LIST=(${SF_LIST[@]+"${SF_LIST[@]}"})

# --- Parameters ---
if [[ -z "${URL}" ]]; then
    usage "url must be the Heimdall server's address, such as https://heimdall.example.com."
fi
authority=${URL#*://}
authority=${authority%%/*}
if [[ "${authority}" == *@* || "${URL}" == *[?#]* ]]; then
    usage "url must not hold credentials, a query or a fragment: the API key goes in the variable api_key names."
fi
if sf_match "${URL}" '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'; then
    PROTO='=https'
elif sf_match "${URL}" '^http://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'; then
    # Plain http only to this machine, so the key never crosses a network
    # in the clear.
    PROTO='=http'
else
    usage "url must be an https:// URL (or http:// to localhost), not '${URL}'."
fi
sf_env_var_name api_key "${API_KEY_VAR}"
API_KEY=${!API_KEY_VAR:-}
if [[ -z "${API_KEY}" ]]; then
    usage "The variable ${API_KEY_VAR} (api_key) is empty or not set: it must hold a Heimdall API key." \
        "Create one in Heimdall under your user's settings, and set it in a CircleCI context or a GitHub secret."
fi
if [[ "${API_KEY}" == *[[:cntrl:]]* ]]; then
    usage "The variable ${API_KEY_VAR} (api_key) holds a control character, such as a newline: it can't be an API key."
fi
# Tags are separated by commas and newlines (Heimdall splits them on commas),
# and may hold spaces.
TAG_LIST=()
while IFS= read -r tag; do
    tag=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "${tag}")
    [[ -z "${tag}" ]] || TAG_LIST+=("${tag}")
done < <(tr ',' '\n' <<< "${TAGS}")
for group in ${GROUPS_LIST[@]+"${GROUPS_LIST[@]}"}; do
    sf_match "${group}" '^[0-9]{1,18}$' || usage "groups takes Heimdall group IDs (numbers), not '${group}'."
done
sf_uint timeout "${TIMEOUT}" 1
if [[ -n "${URLS_ENV_VAR}" ]]; then
    sf_env_var_name evaluation_urls_env_var "${URLS_ENV_VAR}"
fi
for path in "${SF_INPUTS[@]}"; do
    if [[ "${path}" == *[\"\;]* ]]; then
        usage "${path} can't be uploaded: curl can't name a file with \" or ; in its path."
    fi
done

sf_require_jq
for path in "${SF_INPUTS[@]}"; do
    sf_require_hdf "${path}"
done
if ! command -v curl > /dev/null 2>&1; then
    echo "ERROR: curl is not on the PATH, and upload_heimdall needs it." >&2
    exit 1
fi
SF_WORK=$(mktemp -d)
trap 'rm -rf "${SF_WORK}"' EXIT
CURL=(curl -sS --proto "${PROTO}" --max-time "${TIMEOUT}")
# Plain http goes only to this machine, never through a proxy (http_proxy
# applies to localhost too), which would carry the key over a network.
if [[ "${PROTO}" == "=http" ]]; then
    CURL+=(--noproxy '*')
fi
if curl --help all 2> /dev/null | grep -q -- '--fail-with-body'; then
    CURL+=(--fail-with-body)
else
    CURL+=(--fail)
fi

# --- Is it Heimdall, and does it take API keys? ---
status=0
code=$("${CURL[@]}" -o "${SF_WORK}/server.json" -w '%{http_code}' "${URL}/server" 2> "${SF_WORK}/curl.log") || status=$?
if [[ "${status}" -ne 0 ]]; then
    echo "ERROR: Could not reach Heimdall at ${URL}/server (curl exit status ${status}, HTTP status ${code:-none})." >&2
    sf_tail "${SF_WORK}/curl.log" 5
    exit 1
fi
if ! sf_json_is "${SF_WORK}/server.json" 'type == "object" and has("apiKeysEnabled")'; then
    echo "ERROR: ${URL} did not answer as a Heimdall server: GET /server returned no apiKeysEnabled." >&2
    exit 1
fi
if ! sf_json_is "${SF_WORK}/server.json" '.apiKeysEnabled == true'; then
    echo "ERROR: The Heimdall server at ${URL} doesn't take API keys: its administrator must set API_KEY_SECRET." >&2
    exit 1
fi

umask 077
printf 'Authorization: Api-Key %s\n' "${API_KEY}" > "${SF_WORK}/headers"
unset API_KEY

UPLOADS="[]"
URLS=()
echo "Uploading $(sf_plural "${#SF_INPUTS[@]}" "HDF file" "HDF files") to Heimdall at ${URL}."
for path in "${SF_INPUTS[@]}"; do
    name=${path##*/}
    form=(-F "data=@\"${path}\";type=application/json" --form-string "filename=${name}"
        --form-string "public=${PUBLIC}")
    if [[ ${#TAG_LIST[@]} -gt 0 ]]; then
        form+=(--form-string "evaluationTags=$(IFS=,; printf '%s' "${TAG_LIST[*]}")")
    fi
    if [[ ${#GROUPS_LIST[@]} -gt 0 ]]; then
        form+=(--form-string "groups=$(IFS=,; printf '%s' "${GROUPS_LIST[*]}")")
    fi
    status=0
    code=$("${CURL[@]}" -H @"${SF_WORK}/headers" "${form[@]}" -o "${SF_WORK}/response.json" -w '%{http_code}' \
        "${URL}/evaluations" 2> "${SF_WORK}/curl.log") || status=$?
    id=""
    if [[ "${status}" -eq 0 && "${code}" == 201 ]]; then
        id=$(jq -r 'if type == "object" and (.id | type == "string" or type == "number") then .id | tostring else empty end' \
            "${SF_WORK}/response.json" 2> /dev/null) || id=""
    fi
    if [[ -z "${id}" ]] || ! sf_match "${id}" '^[0-9]+$'; then
        echo "ERROR: Heimdall did not store ${path} (curl exit status ${status}, HTTP status ${code:-none})." >&2
        case "${code}" in
            401) echo "  401: Heimdall got no API key." >&2 ;;
            403) echo "  403: Heimdall refused the API key in ${API_KEY_VAR}: it is wrong, or was deleted." >&2 ;;
            413) echo "  413: the file is larger than Heimdall (or a proxy in front of it) takes." >&2 ;;
        esac
        sf_tail "${SF_WORK}/curl.log" 5
        if [[ -s "${SF_WORK}/response.json" ]]; then
            echo "  It answered:" >&2
            head -c 1000 "${SF_WORK}/response.json" | sed 's/^/  /' >&2
            echo >&2
        fi
        if [[ ${#URLS[@]} -gt 0 ]]; then
            echo "  These were stored before it: ${URLS[*]}" >&2
            jq -n --arg url "${URL}" --argjson uploads "${UPLOADS}" '{server: $url, uploads: $uploads}' > "${REPORT}"
        fi
        exit 1
    fi
    link="${URL}/results/${id}"
    URLS+=("${link}")
    UPLOADS=$(jq -c --arg file "${path}" --arg sha "$(sf_sha256 "${path}")" --arg id "${id}" --arg link "${link}" \
        '. + [{file: $file, sha256: $sha, id: $id, url: $link}]' <<< "${UPLOADS}")
    echo "  ${path} -> ${link}"
done

jq -n --arg url "${URL}" --argjson public "${PUBLIC}" --argjson uploads "${UPLOADS}" \
    '{server: $url, public: $public, uploads: $uploads}' > "${REPORT}"
echo "Wrote ${REPORT}."
if [[ -n "${URLS_ENV_VAR}" ]]; then
    sf_export "${URLS_ENV_VAR}" "${URLS[*]}"
    echo "Exported ${URLS_ENV_VAR} with the evaluations' URLs, separated by spaces."
fi
