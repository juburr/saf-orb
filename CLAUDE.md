# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for MITRE's SAF CLI, which converts security tools' results to the Heimdall Data Format (HDF) and checks, summarizes and exports them. The orb installs a checksum-verified SAF CLI and wraps the parts a pipeline needs: `install`, `convert`, `threshold`, `summary`, `export` and `upload_heimdall` (Heimdall's API, with curl). It is not affiliated with MITRE.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh

# Tests (offline; jq, curl, python3 for the stand-in Heimdall, dpkg-deb for the install fixture, and jsonschema for the run record schema)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh threshold input=results.json template_file=threshold.yml

# Print checksum table entries for a new SAF CLI release (needs npm, python3, gpgv, jq, xz and git)
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `install`, `convert`, `threshold`, `summary`, `export`, `upload_heimdall`, one script each in `scripts/`
- `scripts/lib/saf.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_SAF_LIB: << include(scripts/lib/saf.sh) >>` and `eval`ed after a check that it is set. Only defines functions and variables; no `set` line. Its state lives in `SF_` variables, since the SAF CLI's oclif reads `SAF_*` ones.
- `examples/` - Usage examples, pinned to the orb's current version
- `../schemas/run-record.v1.json` - The threshold run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below)

The commands hand each other HDF files through `SAF_HDF_FILES` (`convert`'s `hdf_env_var`), one absolute path per line: `sf_inputs` reads it when `input` is empty. `tests/wiring_test.sh` checks the names agree.

### Install (`scripts/install.sh`, `install_hash.sh`)

`install.sh` follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`, holding the SHA-512 of the release's Debian package (`saf-<version>-<arch>.deb`; 1.6.0's is `saf-v1.6.0-...`). `tests/install_test.sh` is the shared install contract, with this orb's tool fixture; `scripts/cache_key.sh` is shared too. The tool definition:

- **The package.** It holds `usr/lib/@mitre/saf` (the npm package, its `node_modules`, and the official Node.js as `bin/node`) and a `usr/bin/saf` link. `tool_install` unpacks it (with `dpkg-deb -x`, or, when dpkg-deb is missing or can't read it, as dpkg before 1.21.18 can't read zstd, `ar` and the data member's decompressor; one of them is checked for before downloading), checks the tree (`bin/run`, `bin/node`, `package.json` of the version asked for), moves it to `<install_path>/lib/saf`, and writes `<install_path>/bin/saf`, a launcher that runs that node on `bin/run` with `SAF_SKIP_NEW_VERSION_CHECK=true` unless it is set (oclif's warn-if-update-available plugin asks npm once a day otherwise). `bin` holds nothing else, so the package's node never shadows another. It writes `.saf-orb`, the install record (`{tool, version, arch, asset, sha512, verify_checksums}`), smoke-tests the launcher, then swaps the installation in. `install_path` must be missing, hold no files, or be an earlier install, which the record identifies.
- **Mirror.** `saf_download_base_url` reads `download_base_url`, an https mirror that replaces `https://github.com`, refusing credentials, a query or a fragment.

The packages carry no signature, so `install_hash.sh`'s `verify_upstream` ties each to what is signed, with a Python checker (`SAF_CHECK_PY`, written to the work directory and run with `python3 -I`):

1. Once per version (`saf_npm_verified`): npm's `@mitre/saf` packument (the version, at least `SAF_MIN_RELEASE_AGE_DAYS` (7) days old, with attestations), the tarball against its integrity hash, `npm audit signatures` on an `npm install --ignore-scripts` of it (registry signatures and provenance of the whole tree), and the SLSA provenance: subject sha512 is the tarball's, repository `https://github.com/mitre/saf`, a workflow in `SAF_NPM_WORKFLOWS`, and the ref `refs/tags/<version>`, or a branch at the commit `git ls-remote` says the tag points to. Then the lockfile at the provenance's commit, from raw.githubusercontent.com.
2. The package's `ar` members are `debian-binary`, `control.tar*` and `data.tar*`, in that order, and its layout is only `usr/lib/@mitre/saf` and the `usr/bin/saf` link: no symbolic link outside `node_modules`, no `node_modules` below the top, nothing but regular files and directories.
3. Its top-level files are the npm tarball's (`package.json` may differ in `oclif.update`; the Windows `bin/run.cmd` is left out of Linux packages; `bin/node`, `bin/saf`, `bin/saf.cmd` and the lockfile are extra), and its lockfile is the commit's.
4. Every file under `node_modules` belongs to the deepest lockfile package containing it (a bundled one, `inBundle`, to the package bundling it), which must be a production package resolved from registry.npmjs.org with an integrity hash; the files must be exactly the npm tarball's, read as npm (pacote) extracts it: link entries skipped, `package/./x` normalized, a `.gitignore` renamed `.npmignore` unless one is there. Symbolic links must be npm's bin links: `<dir>/node_modules/.bin/NAME` pointing to the file the lockfile's `bin` names for NAME, in a package directly in that `node_modules`. Every package the lockfile installs for production (not dev, optional, peer, link or bundled) must be there.
5. `bin/node` is byte for byte the official Node.js build of the version it reports, whose `SHASUMS256.txt` verifies with `gpgv` against the Node.js release keyring.

Every step in those subshells ends in `|| exit 1`: errexit is off inside a function called as `f || ...`, even in a subshell that sets it. 1.6.0 has no entry: npm's 1.6.0 was built from `main` at a commit its tag doesn't point to. The table covers 1.7.0 and 1.5.3.

To add a release: run `install_hash.sh -v <version>` once it is 7 days old, paste the entries into the table, newest first, and move the default in `install.yml` and `actions/install/action.yml` (and the README's pins and badge) when it is the newest. `tests/wiring_test.sh` requires the default to be the newest table entry. If its asset name changes, add it to `tool_asset_name`; if its publish workflow changes, to `SAF_NPM_WORKFLOWS`. The `install-hash` job in `.github/workflows/actions.yml` runs it for the default.

### What the SAF CLI does that the scripts work around

- **It exits 0 when it fails.** Its commands' `catch` turns an exception into an oclif warning (lines marked ` ›`, `sf_saf_complained`) and exits 0. Some converters only print `Error:` lines and exit 0 without writing anything (`zap2hdf` given a SARIF file: `Error: Unable to process input file`). So every script checks the SAF CLI's stderr and what it wrote. `view summary` exits 1 on a load error; `validate threshold` exits 1 for an unmet threshold.
- **It writes `saf-cli.log` in its working directory.** `sf_saf` runs it in `SF_WORK/run`, with `SAF_SKIP_NEW_VERSION_CHECK=true`; every path it gets is absolute (`sf_abs`). `tests/wiring_test.sh` fails on a call that bypasses `sf_saf`.
- **`validate threshold`** checks only the first profile (`contains[0]`), stops at the first unmet threshold, skips keys it doesn't know, skips `no_impact.total.min`/`.max` (which `saf generate threshold` writes) and a `compliance.max` of 0 (truthiness), fails an empty `controls` list whatever the results, and its flattened-template conversion (`unflattenThreshold`) keeps only the last of `<status>.<x>.min`/`.max`.
- **`trufflehog2hdf`** copies `Raw` and `RawV2` (each secret, in full) into the HDF, so `convert` refuses it.

### Command scripts (`src/scripts/`)

- **`convert.sh`**: `saf convert <from>2hdf -i INPUT -o WORK/out/<report_name>[.json] [-w] [OPTIONS]`. The layouts (`file`, `files` for nessus and snyk, which write `<base>-<target>.json` beside `-o` for several hosts, `dir` for asff, conveyor, prisma, prowler and trivy) and which converters take `-w` are in its `case`. Left out: the ones that read a service (aws_config, ionchannel, msft_secure, sonarqube, splunk) and trufflehog. `extra_args` takes only zap's `--name` (required), nessus's `--parser` and asff's `--securityHub` (made absolute), and is read before an earlier run's HDF is cleared, so `sf_reports_apart` covers the `--securityHub` file too; its problems, like `input`'s, stop the step only after the clearing. The step fails on an exit code, an oclif warning, nothing written, anything but `.json` files, or a file that isn't HDF (`sf_hdf`: an object with a `profiles` array of objects with `controls` arrays). One file becomes `<report_name>.json`; several `<report_name>-<name>.json` (the SAF CLI's name without the report name, `sf_safe_name`d, in C-locale order). `<report_name>.files` lists them, and the next run with the same `report_name` removes those first. It exports `hdf_env_var`.
- **`threshold.sh`**: reads `template_file` or `template_inline` (the SAF CLI's `{key: n}, ...` form) with `TEMPLATE_AWK`, a reader for the plain YAML subset templates need (nesting by spaces, dotted keys, whole numbers, block and flow lists of control IDs; anything else, such as tabs, flow mappings, anchors or a key twice, is refused). Keys must match `COUNT_RE` or `CONTROLS_RE`; compliance is 0 to 100; an empty list, an exact `<status>.total` with a min or max, and a key without a value are refused. The thresholds go to the SAF CLI as one nested JSON document (`-T`), which its YAML reader reads as is. Per file: `saf view summary -f json` for the counts and compliance, then `saf validate threshold`: exit 0 with `All validation tests passed` and no warning passes, exit 1 with an `Error: ` line fails (the message is that line), anything else is no verdict. `own_checks` then checks what validate threshold skips from the summary's counts: `no_impact.total.min`/`.max` and a `compliance.max` of 0. Reports: `<report_name>.json`, JUnit (a test per file), the run record. No verdict on any file fails the step whatever `report_only` says; when that stops it before any file has a result, the report's `error` says why and JUnit has one failed `threshold check` test.
- **`summary.sh`**: `saf view summary -i FILES... -f markdown|json|yaml -o FILE --no-stdout`, checked; the Markdown table goes to the log and, when `GITHUB_STEP_SUMMARY` is set and `step_summary` is true, the job summary.
- **`export.sh`**: `saf convert hdf2<ckl|xccdf|csv|html|caat>` once per file (ckl, xccdf, csv) or once for all (html, caat), into the work directory, then moved. Names: the HDF file's (`base_of`), or `report_name` (with `-<file>` for several). `extra_args` is an allow-list per format (ckl's asset and STIG options, `--metadata` made absolute, and never an output's path; csv's `--fields`, `--noTruncate`; html's `--type`). Each output must exist and look right (`looks_right`: `<CHECKLIST>`...`</CHECKLIST>`, `<Benchmark`...`</Benchmark>`, a CSV header, `<html`...`</html>`, a zip), with no oclif warning and no `Error` line (hdf2ckl prints `Error creating checklist` for bad metadata and exits 0).
- **`upload_heimdall.sh`**: `set +o xtrace`; checks `url` (https, or http to localhost, 127.x or [::1]; no credentials, query or fragment), the key in the variable `api_key` names (no control characters), tags (commas and newlines; Heimdall splits on commas), group IDs, every file is HDF and has no `"` or `;` in its path (curl's `-F` syntax). `GET /server` must say `apiKeysEnabled`. Then one `POST /evaluations` per file: `-F data=@"path";type=application/json`, `--form-string` for `filename` (the file's name), `public`, `evaluationTags`, `groups`, with `-H @<header file>` (`Authorization: Api-Key <key>`, written under `umask 077` in the work directory) and `--proto =https` (or `=http`, with `--noproxy '*'`, since a plain-http server is on this machine), `--fail-with-body` where curl has it. 201 with a numeric `id` is stored, at `<url>/results/<id>`; anything else stops the step, naming what was stored before it. No retry. Heimdall 2.15 answers 401 without a key and 403 for a wrong one.

### Shared helpers (`scripts/lib/saf.sh`)

- From trufflehog-orb's: `sf_subst`, `sf_bool`, `split_shell_words`/`sf_words`, `sf_match` (C locale), `sf_require_jq`, `sf_output`, `sf_uint`, `sf_junit`, `sf_gate`, `sf_plural`, `sf_tail`, `sf_export`, `sf_env_var_name`, `sf_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `sf_sha256`, `sf_url_public`, `sf_ci_json`, `sf_args_json`, `sf_list`.
- The SAF CLI's own: `sf_tool` (`SF_SAF`, `SF_SAF_VERSION` from `@mitre/saf/<version> ...`, `SF_INSTALL_JSON` from `.saf-orb` beside it), `sf_saf`, `sf_saf_complained`, `sf_abs`, `sf_path` (a leading `~` is HOME: CircleCI's env subst doesn't expand it, and configs write `~/...`), `sf_inputs` (sets `SF_INPUTS_ERROR` rather than stopping) and `sf_inputs_check` (stops on it), `sf_reports_apart` (exit 2 when a report a step would clear is a file it reads), `sf_hdf`/`sf_require_hdf`, `sf_top_profiles`, `sf_tool_json`, `sf_files_json`, `sf_safe_name`.
- Each script resolves its inputs before clearing an earlier run's reports, and `sf_reports_apart` keeps it from clearing one that is an input (such as `threshold` with `report_name: scan` after a `convert` that wrote `scan.json`). Inputs that can't be resolved (a missing file, a glob that matches nothing) still clear them, then stop the step, so an earlier run's reports are never stored as this one's.
- Keep `schemas/run-record.v1.json` in step with threshold.sh's `write_record`; `tests/commands_test.sh` checks every run record it writes against it.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults; required parameters are `required: true` inputs). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_SAF_LIB=<lib>`. Inputs never appear inside a `run:` script. `install` restores and saves `actions/cache` with the command's key ingredients. The other actions name their artifact `saf-reports-<report_name>-<random>` and upload `output_dir` with `actions/upload-artifact` under `if: always()` and `store_artifacts`. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. The actions were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. The action descriptions leave out "Environment variables are expanded", since there is no CircleCI CLI on GitHub's runners, and say "action" and "secret" where the commands say "command" and "context". `tests/actions_test.sh` checks all of this.

### Tests

- `tests/install_test.sh`: the shared install contract, with a fixture that builds stand-in Debian packages with `dpkg-deb` (the stand-in binary is the package's `bin/node`, which the launcher runs as `node run ARGS`), then the mirror, the installation's tree and launcher, the install record, and packages without `bin/run`, of another version, or unpacked with `ar` alone, with no dpkg-deb or one that can't read them. The contract needs bash 4.3.
- `tests/commands_test.sh`: every command script through `tests/run_command.sh` (so with its YAML defaults), against a stand-in saf that records each call and answers as the SAF CLI does (including warnings with exit 0), and `tests/fake_heimdall.py`, a stand-in for Heimdall's `GET /server` and `POST /evaluations` on 127.0.0.1 that logs each upload's fields and file. It passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `tests/wiring_test.sh`: every `PARAM_` a script reads is passed, every parameter is used, reports are stored, run steps are named, the README documents every command and action, every SAF CLI run goes through `sf_saf`, `convert` exports what the others read, and install defaults to the newest table entry.
- `tests/fetch_samples.sh DIR`: the SAF CLI's own sample data (tools' results, HDF, threshold templates) at the commit 1.7.0 was built from, for the CI jobs. `tests/check_pipeline.sh DIR` checks what the CI pipeline wrote. `tests/heimdall_server.sh DIR` starts Heimdall 2.15.0 (by digest) and PostgreSQL 17 in Docker on localhost:3000, registers a user and makes an API key.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-env-subst` (env subst and shell conventions), `test-commands` (command and wiring tests, on `cimg/python` with jsonschema), `test-actions`, orb-tools lint, pack and review (`orb_name: saf`), shellcheck.
- `.circleci/test-deploy.yml` - `install-test` (cimg/base, which has no Node.js: the default, its table entry, the cache, 1.5.3), `checksum-test` (the unlisted 1.6.0 refused before downloading, `known_versions` installing it, a local HTTPS mirror serving the real package, then a changed one), `arm64-test`, `pipeline-test` (every command on the sample data: six converters, SAF's own good and bad threshold templates, summary, every export format; steps that must fail through `tests/run_command.sh`; run records against the schema), `heimdall-test` (a machine executor: upload, read the evaluations back, a wrong key failing). Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests`, `install` (amd64 and arm64), `install-from-cache`, `install-hash`, `pipeline` (both architectures), `heimdall`.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `sf_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `upload_heimdall.sh` runs `set +o xtrace` with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself. A parameter that can't work exits 2 (`usage`); a failure after that, 1.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_SAF_LIB}"`). Secrets never go on a command line: the Heimdall API key reaches curl in a header file.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output.

## Naming

Command names say what they do, after the SAF CLI's own where there is one (`convert`, `threshold` for `validate threshold`, `summary` for `view summary`, `export` for the `hdf2*` converters), and `upload_heimdall`. Parameters that map onto one SAF CLI option take its name in snake_case (`include_raw` for `--includeRaw`, `template_file`, `template_inline`, `format`); `from` names the converter, `input` the files read. Plumbing matches the other juburr orbs: `extra_args`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `store_artifacts`; variables a command writes are `<thing>_env_var`; the API key is an `env_var_name` parameter, `api_key`.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh` and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.saf-orb`
- Never run the real SAF CLI on a workstation you don't control; CI runs it
