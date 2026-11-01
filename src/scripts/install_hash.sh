#!/bin/bash
#
# Prints checksum table entries for a SAF CLI release, ready to paste into the
# sha512sums table in install.sh. A development helper: the orb never runs it.
#
#   src/scripts/install_hash.sh -v <version> [-a "<arch> ..."]
#
#   -a  architectures to hash (default: every one install.sh supports)
#
# The SAF CLI's releases publish no checksums for their Debian packages, and
# sign nothing on GitHub. So each package is checked, file by file, against
# what is signed or hashed elsewhere (see verify_upstream) before its entry is
# printed: the npm package (registry signature and SLSA provenance), the
# lockfile at the commit that provenance names, the npm tarball of every
# dependency that lockfile pins, and the Node.js release. Entries go to stdout
# and everything else to stderr, so the output can be pasted as is.
#
# Needs npm (for npm audit signatures), python3, gpgv, xz, and dpkg-deb or ar
# with zstd, besides the shared logic's tools. Downloads the npm package's
# dependency tree (about 500 tarballs) and the Node.js release.

set -euo pipefail

# >>> upstream verification >>>
# A release published to npm fewer than this many days ago is refused, so a
# compromise has time to come to light before the release reaches the table.
# Set SAF_MIN_RELEASE_AGE_DAYS=0 to add a newer release after checking the
# SAF CLI's advisories for it.
SAF_MIN_RELEASE_AGE_DAYS=${SAF_MIN_RELEASE_AGE_DAYS:-7}
# The npm package and the GitHub repository whose release workflow must have
# built it (the workflow's name changed after 1.7.0).
SAF_NPM_PACKAGE="@mitre/saf"
SAF_REPOSITORY="https://github.com/mitre/saf"
SAF_NPM_WORKFLOWS=".github/workflows/push-to-npm-gpr.yml .github/workflows/push-to-npm-gpr-brew.yml"
# The keys that sign Node.js releases, from the Node.js project's own list.
NODE_RELEASE_KEYRING="https://raw.githubusercontent.com/nodejs/release-keys/main/gpg/pubring.kbx"

# saf_check_python: the Python half of verify_upstream, which compares the
# unpacked package with the npm tarball, the lockfile and every dependency's
# tarball, reads the npm metadata and the provenance, and finds which Node.js
# release the package's node is. Run with python3 -I, from a file.
read -r -d '' SAF_CHECK_PY << 'PYEOF' || true
import base64, calendar, hashlib, io, json, os, posixpath, re, sys, tarfile, time, urllib.request

def fail(message):
    print("ERROR: " + message)
    sys.exit(1)

def write(path, text):
    with open(path, "w") as handle:
        handle.write(text + "\n")

def sri_ok(data, integrity):
    algo, _, digest = integrity.partition("-")
    if algo not in ("sha512", "sha384", "sha256", "sha1"):
        return False
    return base64.b64encode(hashlib.new(algo, data).digest()).decode() == digest

def tar_files(data):
    # Regular files of an npm tarball, keyed by their path under its top
    # directory (package/ for most, but not all, packages), as npm (pacote)
    # extracts them: link entries are skipped, a .gitignore becomes a
    # .npmignore unless the tarball already had one there, and a later entry
    # replaces an earlier one at the same path, as tar does.
    files = {}
    npmignores = set()
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            # Some tarballs name members package/./dist/..., which npm
            # extracts to package/dist/...
            name = posixpath.normpath(member.name)
            parts = name.split("/", 1)
            if len(parts) != 2 or not parts[1]:
                continue
            if name.startswith("/") or ".." in name.split("/"):
                fail("an npm tarball names a file outside its directory: %s" % member.name)
            rel = parts[1]
            base = posixpath.basename(rel)
            if base == ".npmignore":
                npmignores.add(rel)
            elif base == ".gitignore":
                rel = rel[: -len(".gitignore")] + ".npmignore"
                if rel in npmignores:
                    continue
            files[rel] = tf.extractfile(member).read()
    return files

def tree_files(root, skip_node_modules):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if skip_node_modules:
            dirnames[:] = [d for d in dirnames if d != "node_modules"]
        for name in filenames:
            out[os.path.normpath(os.path.join(rel_dir, name))] = os.path.join(dirpath, name)
    return out

def npm_meta(packument_path, version, min_age_days):
    doc = json.load(open(packument_path))
    entry = doc.get("versions", {}).get(version)
    if not entry:
        fail("npm has no %s %s." % (doc.get("name"), version))
    dist = entry.get("dist", {})
    published = doc.get("time", {}).get(version, "")
    try:
        when = calendar.timegm(time.strptime(published[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        fail("npm records no publication time for %s." % version)
    age = int((time.time() - when) // 86400)
    if age < min_age_days:
        fail("%s was published to npm %d day(s) ago, on %s, and releases younger than %d days are not added. "
             "Try again later, or set SAF_MIN_RELEASE_AGE_DAYS=0 after checking the SAF CLI's advisories for it."
             % (version, age, published[:10], min_age_days))
    if not dist.get("attestations"):
        fail("npm has no provenance attestation for %s." % version)
    print("ok: npm published %s on %s, %d days ago." % (version, published[:10], age))
    write("npm-dist.json", json.dumps({"tarball": dist["tarball"], "integrity": dist["integrity"]}))

def provenance(path, tarball, repository, workflows, version):
    data = open(tarball, "rb").read()
    sha512 = hashlib.sha512(data).hexdigest()
    found = None
    for attestation in json.load(open(path)).get("attestations", []):
        if not attestation.get("predicateType", "").startswith("https://slsa.dev/provenance/"):
            continue
        payload = attestation["bundle"]["dsseEnvelope"]["payload"]
        statement = json.loads(base64.b64decode(payload))
        found = statement
        break
    if not found:
        fail("npm's attestations for %s hold no SLSA provenance." % version)
    if not any(s.get("digest", {}).get("sha512") == sha512 for s in found.get("subject", [])):
        fail("the provenance is not for this tarball (sha512 %s)." % sha512)
    build = found["predicate"]["buildDefinition"]
    workflow = build.get("externalParameters", {}).get("workflow", {})
    if workflow.get("repository") != repository:
        fail("the provenance names the repository %s, not %s." % (workflow.get("repository"), repository))
    ref = workflow.get("ref", "")
    if ref != "refs/tags/" + version and not re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", ref):
        fail("the provenance names the ref %s, neither refs/tags/%s nor a branch." % (ref, version))
    if workflow.get("path") not in workflows.split():
        fail("the provenance names the workflow %s, which is not a SAF CLI release workflow." % workflow.get("path"))
    commit = ""
    for dep in build.get("resolvedDependencies", []):
        commit = dep.get("digest", {}).get("gitCommit", "")
        if commit:
            break
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail("the provenance names no commit.")
    print("ok: the provenance names %s, %s at %s, commit %s." % (workflow["path"], ref, repository, commit))
    write("commit", commit)
    write("ref", ref)

def bin_link(tree, root_nm, lock, full):
    # npm's bin links: <dir>/node_modules/.bin/NAME, pointing to the file a
    # package in that node_modules directory names for NAME in its "bin".
    rel = os.path.relpath(full, tree)
    parts = rel.split("/")
    target = os.path.normpath(os.path.join(os.path.dirname(rel), os.readlink(full)))
    ok = len(parts) >= 3 and parts[-2] == ".bin" and parts[-3] == "node_modules"
    if ok:
        nm = "/".join(parts[:-2])
        real = os.path.realpath(full)
        ok = real.startswith(os.path.realpath(root_nm) + os.sep) and os.path.isfile(real)
    if ok:
        ok = False
        tparts = target.split("/")
        for i in range(len(tparts) - 1, 0, -1):
            key = "/".join(tparts[:i])
            if key not in lock:
                continue
            # The package must sit directly in that node_modules directory.
            if key.startswith(nm + "/") and re.fullmatch(r"(@[^/]+/)?[^/@][^/]*", key[len(nm) + 1:]):
                bins = lock[key].get("bin") or {}
                named = bins.get(parts[-1]) if isinstance(bins, dict) else None
                ok = named is not None and os.path.normpath(os.path.join(key, named)) == target
            break
    if not ok:
        fail("the package has a symbolic link %s that is not one of npm's bin links." % rel)

def package(tree, tarball, lockfile, cache):
    # The deb's files must be the npm tarball's, the lockfile at the commit
    # the provenance names, and the files of the dependencies it pins. Its
    # node is checked separately; bin/saf and bin/saf.cmd, oclif's own
    # launchers, are never run by saf-orb's launcher.
    published = tar_files(open(tarball, "rb").read())
    files = tree_files(tree, skip_node_modules=True)
    expected_extra = {"bin/node", "bin/saf", "bin/saf.cmd", "package-lock.json"}
    for rel, path in files.items():
        if rel in expected_extra:
            continue
        if rel not in published:
            fail("the package holds %s, which is not in the npm tarball." % rel)
        content = open(path, "rb").read()
        if rel == "package.json":
            mine = json.loads(content)
            theirs = json.loads(published[rel])
            mine.get("oclif", {}).pop("update", None)
            theirs.get("oclif", {}).pop("update", None)
            if mine != theirs:
                fail("the package's package.json differs from the npm tarball's beyond oclif.update.")
        elif content != published[rel]:
            fail("the package's %s differs from the npm tarball's." % rel)
    # oclif leaves the Windows launcher out of its Linux packages.
    windows_only = {"bin/run.cmd"}
    for rel in published:
        if rel not in files and rel not in windows_only:
            fail("the package lacks %s, which the npm tarball has." % rel)
    for rel in ("bin/node", "package-lock.json"):
        if rel not in files:
            fail("the package lacks %s." % rel)
    if open(files["package-lock.json"], "rb").read() != open(lockfile, "rb").read():
        fail("the package's package-lock.json is not the lockfile at the commit the provenance names.")
    print("ok: the package's files are the npm tarball's, and its lockfile is the commit's.")
    lock = json.load(open(lockfile))["packages"]
    # Every file under node_modules belongs to the deepest package directory
    # that contains it, which must be a production package in the lockfile.
    by_package = {}
    root_nm = os.path.join(tree, "node_modules")
    for dirpath, dirnames, filenames in os.walk(root_nm):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                bin_link(tree, root_nm, lock, full)
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, tree)
            if rel == "node_modules/.package-lock.json":
                continue
            # The longest leading path that the lockfile names as a package.
            parts = rel.split("/")
            owner = None
            for i in range(len(parts) - 1, 1, -1):
                candidate = "/".join(parts[:i])
                if candidate in lock:
                    owner = candidate
                    break
            if owner is None:
                fail("%s belongs to no package in the lockfile." % rel)
            # npm installs a bundled dependency (inBundle) from the tarball
            # of the package that bundles it, not from its own.
            while lock[owner].get("inBundle"):
                parent = owner.rsplit("/node_modules/", 1)[0]
                if parent == owner or parent not in lock:
                    fail("%s is bundled by no package in the lockfile." % owner)
                owner = parent
            by_package.setdefault(owner, {})[rel[len(owner) + 1:]] = full
    checked = 0
    for key in sorted(by_package):
        entry = lock[key]
        if entry.get("dev") or entry.get("link"):
            fail("the package holds %s, which the lockfile marks as a development or linked package." % key)
        resolved, integrity = entry.get("resolved", ""), entry.get("integrity", "")
        if not resolved.startswith("https://registry.npmjs.org/") or not integrity:
            fail("the lockfile pins %s to %s, not to an npm tarball with an integrity hash." % (key, resolved or "nothing"))
        cached = os.path.join(cache, hashlib.sha256(resolved.encode()).hexdigest() + ".tgz")
        if os.path.exists(cached):
            data = open(cached, "rb").read()
        else:
            data = urllib.request.urlopen(resolved, timeout=120).read()
            if not sri_ok(data, integrity):
                fail("the npm tarball of %s does not match the lockfile's integrity hash." % key)
            with open(cached, "wb") as handle:
                handle.write(data)
        if not sri_ok(data, integrity):
            fail("the npm tarball of %s does not match the lockfile's integrity hash." % key)
        theirs = tar_files(data)
        mine = by_package[key]
        for rel, path in mine.items():
            if rel not in theirs:
                fail("the package's %s/%s is not in that dependency's npm tarball." % (key, rel))
            if open(path, "rb").read() != theirs[rel]:
                fail("the package's %s/%s differs from that dependency's npm tarball." % (key, rel))
        for rel in theirs:
            if rel not in mine:
                fail("the package lacks %s/%s, which that dependency's npm tarball has." % (key, rel))
        checked += 1
    print("ok: node_modules holds %d packages, each file for file the npm tarball the lockfile pins." % checked)

def node_version(binary):
    counts = {}
    for match in re.finditer(rb"v([0-9]{2})\.([0-9]{1,3})\.([0-9]{1,3})\x00", open(binary, "rb").read()):
        version = b".".join(match.groups()).decode()
        counts[version] = counts.get(version, 0) + 1
    if not counts:
        fail("could not tell which Node.js release the package's node is.")
    print(max(counts, key=counts.get))

command = sys.argv[1]
if command == "npm-meta":
    npm_meta(sys.argv[2], sys.argv[3], int(sys.argv[4]))
elif command == "integrity":
    if not sri_ok(open(sys.argv[2], "rb").read(), sys.argv[3]):
        fail("the npm tarball does not match its integrity hash.")
elif command == "provenance":
    provenance(*sys.argv[2:7])
elif command == "package":
    package(*sys.argv[2:6])
elif command == "node-version":
    node_version(sys.argv[2])
else:
    fail("unknown command " + command)
PYEOF

saf_py() {
    python3 -I "${HASH_WORK_DIR}/saf_check.py" "$@"
}

# saf_npm_verified VERSION: the checks that are the same for every
# architecture, done once into ${HASH_WORK_DIR}/npm: the npm package's
# metadata and age, its tarball against the integrity hash, the registry
# signatures and provenance attestations of it and its dependency tree (npm
# audit signatures, which verifies each attestation's Sigstore bundle), which
# repository, tag, workflow and commit the provenance names, and the
# lockfile at that commit.
saf_npm_verified() {
    local dir="${HASH_WORK_DIR}/npm" dist tarball integrity commit ref tagged
    if [[ -f "${dir}/done" ]]; then
        return 0
    fi
    mkdir -p "${dir}/tarballs" "${dir}/project"
    printf '%s\n' "${SAF_CHECK_PY}" > "${HASH_WORK_DIR}/saf_check.py"
    (
        set -euo pipefail
        cd "${dir}" || exit 1
        hash_fetch "https://registry.npmjs.org/$(printf '%s' "${SAF_NPM_PACKAGE}" | sed 's#/#%2f#')" packument.json \
            || { echo "ERROR: could not read ${SAF_NPM_PACKAGE} from npm."; exit 1; }
        saf_py npm-meta packument.json "$1" "${SAF_MIN_RELEASE_AGE_DAYS}" || exit 1
        dist=$(cat npm-dist.json) || exit 1
        tarball=$(jq -r '.tarball' <<< "${dist}") || exit 1
        integrity=$(jq -r '.integrity' <<< "${dist}") || exit 1
        hash_fetch "${tarball}" saf.tgz || { echo "ERROR: could not download ${tarball}."; exit 1; }
        saf_py integrity saf.tgz "${integrity}" || exit 1
        echo "ok: ${tarball##*/} matches npm's integrity hash."
        # npm audit signatures verifies the registry signature of every
        # installed package and every provenance attestation npm has for
        # one, including the SAF CLI's. --ignore-scripts: nothing installed
        # runs.
        (
            cd project || exit 1
            printf '{"name":"saf-orb-verify","version":"0.0.0","private":true}\n' > package.json || exit 1
            npm install --ignore-scripts --no-audit --no-fund --loglevel=error "${SAF_NPM_PACKAGE}@$1" > install.log 2>&1 \
                || { tail -n 20 install.log; echo "ERROR: npm could not install ${SAF_NPM_PACKAGE}@$1 to check its signatures."; exit 1; }
            npm audit signatures > audit.log 2>&1 \
                || { cat audit.log; echo "ERROR: npm audit signatures failed for ${SAF_NPM_PACKAGE}@$1 and its dependencies."; exit 1; }
            sed 's/^/  /' audit.log | grep -v '^  *$'
            grep -q 'have verified attestations\|has a verified attestation' audit.log \
                || { echo "ERROR: npm audit signatures verified no attestation."; exit 1; }
        ) || exit 1
        echo "ok: npm audit signatures verified ${SAF_NPM_PACKAGE}@$1's registry signature and provenance."
        hash_fetch "https://registry.npmjs.org/-/npm/v1/attestations/$(printf '%s' "${SAF_NPM_PACKAGE}" | sed 's#/#%2f#')@$1" \
            attestations.json || { echo "ERROR: could not read npm's attestations for $1."; exit 1; }
        saf_py provenance attestations.json saf.tgz "${SAF_REPOSITORY}" "${SAF_NPM_WORKFLOWS}" "$1" || exit 1
        commit=$(cat commit) || exit 1
        ref=$(cat ref) || exit 1
        # A release published from a branch (1.6.0 was, from main) must be
        # the commit its tag points to.
        if [[ "${ref}" != "refs/tags/$1" ]]; then
            tagged=$(git ls-remote "${SAF_REPOSITORY}" "refs/tags/$1" "refs/tags/$1^{}" | awk '
                $2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { plain = $1 }
                END { print (peeled != "" ? peeled : plain) }') \
                || { echo "ERROR: could not read tag $1 from ${SAF_REPOSITORY}."; exit 1; }
            if [[ "${tagged}" != "${commit}" ]]; then
                echo "ERROR: the provenance names ${ref} at ${commit}, but tag $1 points to ${tagged:-nothing}."
                exit 1
            fi
            echo "ok: tag $1 points to ${commit}, the commit the provenance names."
        fi
        hash_fetch "https://raw.githubusercontent.com/mitre/saf/${commit}/package-lock.json" package-lock.json \
            || { echo "ERROR: could not download package-lock.json at ${commit}."; exit 1; }
        touch ./done || exit 1
    )
}

# saf_node_verified VERSION ARCH: downloads the Node.js release VERSION for
# ARCH, checks it against SHASUMS256.txt.asc, which gpgv verifies with the
# Node.js release keys, and leaves its bin/node in node-<VERSION>-<ARCH>.
saf_node_verified() {
    local dir="${HASH_WORK_DIR}/node" arch=x64 archive
    [[ "$2" == arm64 ]] && arch=arm64
    archive="node-v$1-linux-${arch}.tar.xz"
    mkdir -p "${dir}"
    (
        set -euo pipefail
        cd "${dir}" || exit 1
        if [[ ! -f pubring.kbx ]]; then
            hash_fetch "${NODE_RELEASE_KEYRING}" pubring.kbx || { echo "ERROR: could not download the Node.js release keys."; exit 1; }
        fi
        if [[ ! -f "SHASUMS256-$1.txt" ]]; then
            hash_fetch "https://nodejs.org/dist/v$1/SHASUMS256.txt.asc" "SHASUMS256-$1.txt.asc" \
                || { echo "ERROR: could not download Node.js $1's SHASUMS256.txt.asc."; exit 1; }
            gpgv --keyring "${dir}/pubring.kbx" --output "SHASUMS256-$1.txt" "SHASUMS256-$1.txt.asc" > gpgv.log 2>&1 \
                || { cat gpgv.log; echo "ERROR: Node.js $1's SHASUMS256.txt.asc is not signed by a Node.js release key."; exit 1; }
            echo "ok: Node.js $1's SHASUMS256.txt is signed by a Node.js release key."
        fi
        hash_fetch "https://nodejs.org/dist/v$1/${archive}" "${archive}" || { echo "ERROR: could not download ${archive}."; exit 1; }
        if [[ "$(sha256sum "${archive}" | awk '{ print $1 }')" != \
            "$(awk -v name="${archive}" '$2 == name { print $1 }' "SHASUMS256-$1.txt")" ]]; then
            echo "ERROR: ${archive} does not match the signed SHASUMS256.txt."
            exit 1
        fi
        tar -xJf "${archive}" -O "node-v$1-linux-${arch}/bin/node" > "node-$1-$2" \
            || { echo "ERROR: could not unpack bin/node from ${archive}."; exit 1; }
        echo "ok: ${archive} matches the signed SHASUMS256.txt."
    )
}

# verify_upstream VERSION ARCH PACKAGE: checks the Debian package against
# what is signed or hashed upstream: saf_npm_verified, then the package's
# files against the npm tarball, the lockfile and the dependencies' tarballs,
# then its node against the Node.js release. Returns 0 when everything
# matches, and 1 otherwise: there is no unverified entry for a SAF CLI
# release.
verify_upstream() {
    local tree="${PWD}/unpacked" node version tool
    for tool in npm python3 gpgv jq xz git; do
        command -v "${tool}" > /dev/null || { echo "ERROR: ${tool} is required to verify the SAF CLI's package."; return 1; }
    done
    saf_npm_verified "$1" || return 1
    rm -rf "${tree}" && mkdir -p "${tree}"
    if ! (ORB_ASSET_NAME=${3##*/} saf_unpack "$3" "${tree}") > unpack.log 2>&1; then
        cat unpack.log
        echo "ERROR: could not unpack ${3##*/}."
        return 1
    fi
    if [[ -n "$(find "${tree}" -mindepth 1 -maxdepth 1 ! -name usr)" ]] \
        || [[ -n "$(find "${tree}/usr" -mindepth 1 -maxdepth 1 ! -name lib ! -name bin)" ]] \
        || [[ "$(readlink "${tree}/usr/bin/saf" 2> /dev/null)" != "../lib/@mitre/saf/bin/saf" ]] \
        || [[ "$(find "${tree}/usr/bin" -mindepth 1 | wc -l)" -ne 1 ]] \
        || [[ "$(find "${tree}/usr/lib" -mindepth 1 -maxdepth 2 | tr '\n' ' ')" != "${tree}/usr/lib/@mitre ${tree}/usr/lib/@mitre/saf " ]]; then
        echo "ERROR: ${3##*/} holds files other than usr/lib/@mitre/saf and the usr/bin/saf link to it."
        return 1
    fi
    saf_py package "${tree}/usr/lib/@mitre/saf" "${HASH_WORK_DIR}/npm/saf.tgz" "${HASH_WORK_DIR}/npm/package-lock.json" \
        "${HASH_WORK_DIR}/npm/tarballs" || return 1
    version=$(saf_py node-version "${tree}/usr/lib/@mitre/saf/bin/node") || { echo "${version}"; return 1; }
    saf_node_verified "${version}" "$2" || return 1
    node="${HASH_WORK_DIR}/node/node-${version}-$2"
    if ! cmp -s "${node}" "${tree}/usr/lib/@mitre/saf/bin/node"; then
        echo "ERROR: the package's node is not Node.js ${version}'s linux $2 build."
        return 1
    fi
    echo "ok: the package's node is Node.js ${version}'s official linux $2 build."
    rm -rf "${tree}"
}
# <<< upstream verification <<<

# >>> shared install_hash logic >>>
# Everything from here to the end marker is identical in the install_hash.sh
# of every juburr orb. The tool definition, and with it the asset names and
# URLs, is read from install.sh so the two scripts cannot disagree.

hash_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_usage() {
    printf 'Usage: %s -v <version> [-a "<arch> ..."] [-c SHA-256:<hex> | -c SHA1:<hex> | -c NONE]\n' "$0" >&2
    exit 1
}

# hash_fetch URL DEST [CURL_ARG...]: downloads URL to DEST for verify_upstream.
# Returns 0 on success, 2 when the server says there is no such file (404),
# and 1 on any other failure, which must never be read as "not published".
hash_fetch() {
    local url=$1 dest=$2 code rc=0
    shift 2
    # Without -f, curl exits 0 on an HTTP error, so a non-zero exit is a
    # transfer failure, such as a connection that closed partway.
    code=$(curl -sSL --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 30 \
        -o "${dest}" -w '%{http_code}' "$@" "${url}") || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: could not download ${url} (curl exit code ${rc})."
        return 1
    fi
    case "${code}" in
        200) return 0 ;;
        404) return 2 ;;
        *)
            echo "ERROR: could not download ${url} (HTTP status ${code:-none})."
            return 1
            ;;
    esac
}

# hash_version_le A B: succeeds if version A sorts at or before version B.
hash_version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Loads install.sh's tool definition and shared functions, without its
# checksum table or main call.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SCRIPT}")
if ! declare -F tool_asset_name > /dev/null; then
    hash_die "Could not load the tool definition from ${INSTALL_SCRIPT}."
fi

VERSION=""
ARCHES=""
UPSTREAM_CHECKSUM=""
while getopts ':v:a:c:' flag; do
    case "${flag}" in
        v) VERSION=${OPTARG} ;;
        a) ARCHES=${OPTARG} ;;
        c) UPSTREAM_CHECKSUM=${OPTARG} ;;
        *) hash_usage ;;
    esac
done
VERSION=${VERSION#v}
if [[ -z "${VERSION}" ]]; then
    hash_usage
fi
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    hash_die "Invalid version '${VERSION}'."
fi
ARCHES=${ARCHES:-${TOOL_ARCHES}}
read -r -a ARCH_LIST <<< "${ARCHES}"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
    hash_die "-a names no architecture. Supported: ${TOOL_ARCHES}."
fi
for arch in "${ARCH_LIST[@]}"; do
    if [[ " ${TOOL_ARCHES} " != *" ${arch} "* ]]; then
        hash_die "Unsupported architecture '${arch}'. Supported: ${TOOL_ARCHES}."
    fi
done
if [[ -n "${UPSTREAM_CHECKSUM}" && "${UPSTREAM_CHECKSUM}" != "NONE" ]]; then
    if [[ ! "${UPSTREAM_CHECKSUM}" =~ ^(SHA-256:[0-9a-f]{64}|SHA1:[0-9a-f]{40})$ ]]; then
        hash_die "-c must be SHA-256:<hex>, SHA1:<hex>, or NONE."
    fi
    if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
        hash_die "-c describes one asset, so pick its architecture with -a."
    fi
fi
REQUIRED_TOOLS=(curl sha256sum sha512sum tar gzip)
if [[ "${UPSTREAM_CHECKSUM}" == SHA1:* ]]; then
    REQUIRED_TOOLS+=(sha1sum)
fi
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "${tool}" > /dev/null || hash_die "${tool} is required."
done

HASH_WORK_DIR=$(mktemp -d)
trap 'rm -rf "${HASH_WORK_DIR}"' EXIT

# check_upstream VERSION ARCH ASSET: anchors ASSET to what the project
# published, via verify_upstream (which returns 2 when nothing was published)
# and any checksum supplied with -c.
check_upstream() {
    local rc=0 expected actual
    (cd "${3%/*}" && verify_upstream "$1" "$2" "$3") >&2 || rc=$?
    if [[ "${rc}" -ne 0 && "${rc}" -ne 2 ]]; then
        hash_die "${3##*/} could not be verified against what ${TOOL_NAME} published for ${1}."
    fi
    # NONE only stands in for a checksum that was never published.
    if [[ "${UPSTREAM_CHECKSUM}" == "NONE" ]]; then
        if [[ "${rc}" -eq 2 ]]; then
            printf 'WARN: -c NONE: %s is not checked against any published checksum.\n' "${3##*/}" >&2
        fi
        return 0
    fi
    if [[ -n "${UPSTREAM_CHECKSUM}" ]]; then
        expected=${UPSTREAM_CHECKSUM#*:}
        case "${UPSTREAM_CHECKSUM%%:*}" in
            SHA-256) actual=$(sha256sum "$3" | awk '{ print $1 }') ;;
            SHA1) actual=$(sha1sum "$3" | awk '{ print $1 }') ;;
        esac
        if [[ "${actual}" != "${expected}" ]]; then
            hash_die "${3##*/} does not match the checksum given with -c (${actual})."
        fi
        printf 'ok: %s matches the checksum given with -c.\n' "${3##*/}" >&2
    elif [[ "${rc}" -eq 2 ]]; then
        hash_die "${TOOL_NAME} published no checksum for ${3##*/}. Supply one from another official source with -c," \
            "or pass -c NONE to add the entry unanchored."
    fi
}

ENTRIES=()
for arch in "${ARCH_LIST[@]}"; do
    # orb_extract works in ORB_WORK_DIR and names ORB_ASSET_NAME in messages.
    ORB_WORK_DIR="${HASH_WORK_DIR}/${arch}"
    ORB_ASSET_NAME=$(tool_asset_name "${VERSION}" "${arch}")
    member=$(tool_archive_member "${VERSION}" "${arch}")
    mkdir -p "${ORB_WORK_DIR}"
    mapfile -t urls < <(tool_asset_urls "${VERSION}" "${arch}" "${ORB_ASSET_NAME}")
    if ! orb_download "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${urls[@]}" >&2; then
        hash_die "Could not download ${ORB_ASSET_NAME}. If ${TOOL_NAME} ${VERSION} has no ${arch} build," \
            "leave ${arch} out with -a."
    fi
    check_upstream "${VERSION}" "${arch}" "${ORB_WORK_DIR}/${ORB_ASSET_NAME}"
    # Hashes the same file install.sh verifies, with the same checks on it.
    if ! orb_extract "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${member}" >&2; then
        hash_die "Could not take ${member} from ${ORB_ASSET_NAME}."
    fi
    ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${VERSION}" "${arch}" "$(sha512sum "${ORB_VERIFIED_FILE}" | awk '{ print $1 }')")")
done
# Nothing is printed until every architecture has passed.
printf '%s\n' "${ENTRIES[@]}"
# <<< shared install_hash logic <<<
