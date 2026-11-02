#!/usr/bin/env bash
#
# Starts a Heimdall server for the CI jobs, with Docker: Heimdall 2.15.0,
# pinned by digest, and PostgreSQL 17, on http://localhost:3000, with API
# keys enabled. Then it registers a user, logs in, and makes an API key for
# it, through Heimdall's API, as a person would in its web page.
#
# It writes, in DIR, each mode 0600:
#   api-key   the API key, for upload_heimdall
#   jwt       the user's session token, to read the evaluations back
#
# The secrets are made here with openssl, and reach Docker in an env file,
# never on a command line.
#
# Usage, from a checkout:
#   bash tests/heimdall_server.sh DIR

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 DIR" >&2
    exit 2
fi
DIR=$1
HEIMDALL_IMAGE="mitre/heimdall2:2.15.0@sha256:a728495d0e8a794d5018002bff8917d84775afc477c558b447b9682247839880"
POSTGRES_IMAGE="postgres:17"
URL="http://localhost:3000"
EMAIL="ci@example.com"

umask 077
mkdir -p "${DIR}"
DB_PASSWORD=$(openssl rand -hex 24)
printf 'POSTGRES_DB=heimdall-server-production\nPOSTGRES_PASSWORD=%s\n' "${DB_PASSWORD}" > "${DIR}/postgres.env"
printf '%s\n' "NODE_ENV=production" "DATABASE_HOST=heimdall-db" "DATABASE_PASSWORD=${DB_PASSWORD}" \
    "JWT_SECRET=$(openssl rand -hex 32)" "JWT_EXPIRE_TIME=1h" "API_KEY_SECRET=$(openssl rand -hex 32)" \
    "EXTERNAL_URL=${URL}" > "${DIR}/heimdall.env"

docker network create heimdall > /dev/null
docker run -d --name heimdall-db --network heimdall --env-file "${DIR}/postgres.env" "${POSTGRES_IMAGE}" > /dev/null
# Heimdall's image migrates the database when it starts, and retries until
# the database answers.
docker run -d --name heimdall --network heimdall -p 127.0.0.1:3000:3000 --env-file "${DIR}/heimdall.env" \
    "${HEIMDALL_IMAGE}" > /dev/null

echo "Waiting for Heimdall at ${URL}..."
for _ in $(seq 1 120); do
    if curl -sf "${URL}/server" -o "${DIR}/server.json" 2> /dev/null; then
        break
    fi
    sleep 3
done
if [[ ! -s "${DIR}/server.json" ]]; then
    echo "ERROR: Heimdall did not start. Its log ends:" >&2
    docker logs heimdall 2>&1 | tail -n 40 >&2
    exit 1
fi
if [[ "$(jq -r .apiKeysEnabled "${DIR}/server.json")" != true ]]; then
    echo "ERROR: Heimdall started without API keys." >&2
    exit 1
fi
echo "Heimdall is up."

# A password that meets Heimdall's rules: 15 characters or more, with upper
# and lower case letters, digits and symbols, never four of a kind in a row.
# The server only lives as long as the CI job, and listens on localhost.
PASSWORD='Aa1!Bb2@Cc3#Dd4$'
# post PATH BODY [AUTH_HEADER_FILE]: POSTs JSON to Heimdall and prints the answer.
post() {
    local headers=(-H 'Content-Type: application/json')
    if [[ $# -gt 2 ]]; then
        headers+=(-H @"$3")
    fi
    curl -sS --fail-with-body "${headers[@]}" --data-binary @- "${URL}$1" <<< "$2"
}
post /users "$(jq -cn --arg email "${EMAIL}" --arg password "${PASSWORD}" \
    '{email: $email, password: $password, passwordConfirmation: $password, firstName: "CI", lastName: "Test",
      role: "user", creationMethod: "local"}')" > /dev/null
post /authn/login "$(jq -cn --arg email "${EMAIL}" --arg password "${PASSWORD}" '{email: $email, password: $password}')" \
    | jq -r .accessToken > "${DIR}/jwt"
printf 'Authorization: Bearer %s\n' "$(cat "${DIR}/jwt")" > "${DIR}/bearer"
post /apikeys "$(jq -cn --arg password "${PASSWORD}" '{name: "saf-orb CI", currentPassword: $password}')" "${DIR}/bearer" \
    | jq -r .apiKey > "${DIR}/api-key"
if [[ ! -s "${DIR}/api-key" || "$(cat "${DIR}/api-key")" == null ]]; then
    echo "ERROR: Heimdall made no API key." >&2
    exit 1
fi
echo "Registered ${EMAIL} and made an API key for it in ${DIR}/api-key."
