#!/usr/bin/env bash
# Deterministic matrix for fail-closed store-reference validation.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'
opaque='/nix/store/11111111111111111111111111111111-opaque'
drv='/nix/store/22222222222222222222222222222222-build.drv'
requisite='/nix/store/33333333333333333333333333333333-requisite'
at_path='/nix/store/44444444444444444444444444444444-at-path'
stale='/nix/store/55555555555555555555555555555555-stale'
recoverable='/nix/store/66666666666666666666666666666666-recoverable'
hydrate_set="${recoverable}"
valid_set="${opaque}:${drv}:${requisite}:${at_path}"

mkdir -p "${work}/bin"
cat >"${work}/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\t%s\n' "$*" >>"${MOCK_LOG}"
if [ "$1" = --check-validity ]; then
  [ "${MOCK_MODE}" != validity-fail ] || exit 1
  shift
  printf 'validity-paths\t%s\n' "$*" >>"${MOCK_LOG}"
  for path in "$@"; do
    case ":${MOCK_VALID_SET}:" in *":${path}:"*) continue ;; esac
    grep -qxF "${path}" "${MOCK_HYDRATE_STATE}" 2>/dev/null || exit 1
  done
  exit 0
fi
if [ "$1" = --query ] && [ "$2" = --requisites ]; then
  [ "${MOCK_MODE}" != closure-fail ] || exit 1
  shift 2
  [ "${MOCK_MODE}" != closure-empty ] || exit 0
  for path in "$@"; do
    if [ "${MOCK_MODE}" = closure-omit-root ] \
      && [ "$path" = '/nix/store/22222222222222222222222222222222-build.drv' ]; then
      printf '%s\n' '/nix/store/33333333333333333333333333333333-requisite'
      continue
    fi
    printf '%s\n' "$path"
    [ "$path" != '/nix/store/22222222222222222222222222222222-build.drv' ] \
      || printf '%s\n' '/nix/store/33333333333333333333333333333333-requisite'
  done
  [ "${MOCK_MODE}" != closure-malformed ] || printf '%s\n' 'malformed-closure-output'
  exit 0
fi
exit 1
EOF
chmod +x "${work}/bin/nix-store"
cat >"${work}/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix-call\t%s\n' "$*" >>"${MOCK_LOG}"
if [ "$1" = config ] && [ "$2" = show ] && [ "$3" = substituters ]; then
  [ "${MOCK_MODE}" != hydrate-legacy ] || exit 1
  case "${MOCK_MODE}" in hydrate|hydrate-validity-fail) printf 'file:///tmp/test-substituter\n'; exit 0 ;; esac
  exit 1
fi
if [ "$1" = show-config ] && [ "$2" = substituters ]; then
  [ "${MOCK_MODE}" = hydrate-legacy ] || exit 1
  printf 'substituters = file:///tmp/test-substituter\n'
  exit 0
fi
if [ "$1" = copy ] && [ "$2" = --from ]; then
  case "${MOCK_MODE}" in hydrate|hydrate-legacy|hydrate-validity-fail) ;; *) exit 1 ;; esac
  from="$3"
  [ "${from}" = file:///tmp/test-substituter ] || exit 1
  shift 3
  for path in "$@"; do
    [ "$path" = -- ] && continue
    [ "$path" = '/nix/store/66666666666666666666666666666666-recoverable' ] || exit 1
    printf 'hydrated\t%s\t%s\n' "${from}" "${path}" >>"${MOCK_LOG}"
    [ "${MOCK_MODE}" = hydrate-validity-fail ] || printf '%s\n' "${path}" >>"${MOCK_HYDRATE_STATE}"
  done
  exit 0
fi
exit 1
EOF
chmod +x "${work}/bin/nix"
missing_nix_store_bin="${work}/bin-without-nix-store"
mkdir -p "${missing_nix_store_bin}"
for utility in bash comm cp cut dirname grep mkdir mktemp mv rm sed sha256sum sort tr wc xargs; do
  ln -s "$(command -v "${utility}")" "${missing_nix_store_bin}/${utility}"
done

fail() { echo "restore-context-matrix: $1" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
bytes() { wc -c <"$1" | tr -d ' '; }
case_number=0

run_case() {
  local label="$1" kind="$2" value="$3" context="$4" expected="$5"
  local mode="${6:-normal}" tool_path="${7:-${work}/bin:${PATH}}"
  local case_dir staging snapshot manifest home live destination output log
  case_number=$((case_number + 1))
  case_dir="${work}/case-${case_number}-${label}"
  staging="${case_dir}/staging"
  home="${case_dir}/home"
  live="${case_dir}/live/nix-eval-cache.db"
  output="${case_dir}/output"
  log="${case_dir}/commands"
  hydrate_state="${case_dir}/hydrated"
  mkdir -p "${staging}/nix-eval-cache-v6" "$(dirname "${live}")" "${home}"
  : >"${hydrate_state}"
  printf 'live-sentinel' >"${live}"
  : >"${output}"
  : >"${log}"

  if [ "${kind}" = E ]; then
    snapshot="${staging}/nix-eval-cache.db"
    if [ "${mode}" = sqlite-fail ]; then
      "${sqlite3_path}" "${snapshot}" 'CREATE TABLE unrelated(value TEXT);'
    else
      "${sqlite3_path}" "${snapshot}" \
        "CREATE TABLE cached_eval(json_output TEXT NOT NULL); CREATE TABLE eval_resource_spec(spec TEXT NOT NULL); INSERT INTO cached_eval VALUES ('${value}'); INSERT INTO eval_resource_spec VALUES ('fixture');"
    fi
    printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":{"name":"nix-eval-cache.db","sha256":"%s","bytes":%s},"nixEvalFiles":[]}' \
      "${key}" "$(sha "${snapshot}")" "$(bytes "${snapshot}")" >"${staging}/manifest.json"
    destination="${live}"
  else
    snapshot="${staging}/nix-eval-cache-v6/candidate.sqlite"
    if [ "${mode}" = sqlite-fail ]; then
      "${sqlite3_path}" "${snapshot}" 'CREATE TABLE unrelated(value TEXT);'
    else
      "${sqlite3_path}" "${snapshot}" \
        "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('${value}', $(if [ -n "${context}" ]; then printf "'%s'" "${context}"; else printf NULL; fi));"
    fi
    printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":null,"nixEvalFiles":[{"name":"candidate.sqlite","sha256":"%s","bytes":%s}]}' \
      "${key}" "$(sha "${snapshot}")" "$(bytes "${snapshot}")" >"${staging}/manifest.json"
    destination="${home}/.cache/nix/eval-cache-v6/candidate.sqlite"
    mkdir -p "$(dirname "${destination}")"
    printf 'live-sentinel' >"${destination}"
  fi
  manifest="${staging}/manifest.json"

PATH="${tool_path}" HOME="${home}" STAGING_DIR="${staging}" MANIFEST="${manifest}" \
LIVE_DB="${live}" SQLITE3_PATH="${sqlite3_path}" EXPECTED_KEY="${key}" \
DEVENV_VERSION='test-version' CACHE_EVAL='true' CACHE_NIX_EVAL='true' \
GITHUB_OUTPUT="${output}" MOCK_LOG="${log}" MOCK_MODE="${mode}" \
MOCK_VALID_SET="${valid_set}" MOCK_HYDRATE_STATE="${hydrate_state}" \
  bash "${root}/restore-eval-cache.sh"

  if [ "${expected}" = accept ]; then
    [ "$(${sqlite3_path} "${destination}" 'PRAGMA quick_check;' | tr -d '\n')" = ok ] \
      || fail "${label}: accepted candidate was not installed"
    if [ "${kind}" = E ]; then
      grep -qx 'eval-cache-restored=true' "${output}" || fail "${label}: missing eval restore output"
    else
      grep -qx 'nix-eval-cache-restored=true' "${output}" || fail "${label}: missing Nix restore output"
      grep -qx 'nix-eval-files-restored=1' "${output}" || fail "${label}: wrong installed count"
    fi
  else
    [ "$(cat "${destination}")" = live-sentinel ] || fail "${label}: rejected candidate replaced live sentinel"
    if [ "${kind}" = E ]; then
      ! grep -qx 'eval-cache-restored=true' "${output}" || fail "${label}: rejected eval candidate reported restored"
    else
      grep -qx 'nix-eval-files-restored=0' "${output}" || fail "${label}: rejected Nix candidate counted"
    fi
  fi
  LAST_LOG="${log}"
}

# Both database classes extract complete direct references from text fields.
run_case eval-direct E "${opaque}" '' accept
run_case eval-stale E "${stale}" '' reject
run_case eval-recoverable E "${recoverable}" '' reject
run_case nix-direct N "${opaque}" '' accept
run_case nix-stale N "${stale}" '' reject
run_case nix-recoverable N "${recoverable}" '' reject

# Supported context grammar: opaque, derivation, recursive output prefixes, and @ paths.
run_case context-opaque N fixture "${opaque}" accept
run_case context-drv N fixture "=${drv#/nix/store/}" accept
run_case context-output N fixture "!out!${drv#/nix/store/}" accept
run_case context-newline N fixture "${opaque}"$'\n'"${at_path}" reject
run_case context-recursive-output N fixture "!out!!dev!${drv#/nix/store/}" accept
run_case context-at N fixture "@${at_path#/nix/store/}" accept

# Every malformed, partial, or unknown non-empty element rejects the candidate.
run_case context-malformed N fixture '!out!' reject
run_case context-partial N fixture '/nix/store/11111111111111111111111111111111-opaque/trailing' reject
run_case context-unknown N fixture 'plain-token' reject
run_case hydrate-legacy-cli E "${recoverable}" '' accept hydrate-legacy
run_case hydrate-validity-failure E "${recoverable}" '' reject hydrate-validity-fail
run_case nix-hydrate-validity-failure N "${recoverable}" '' reject hydrate-validity-fail

# Every accepted hydration copies the exact path, then re-checks that path before installing.
run_case hydrate-revalidation E "${recoverable}" '' accept hydrate
[ "$(grep -c $'^hydrated\tfile:///tmp/test-substituter\t/nix/store/66666666666666666666666666666666-recoverable$' "${LAST_LOG}")" -eq 1 ] \
  || fail 'hydrate-revalidation: expected one exact-path copy'
[ "$(grep -c $'^validity-paths\t/nix/store/66666666666666666666666666666666-recoverable$' "${LAST_LOG}")" -eq 3 ] \
  || fail 'hydrate-revalidation: expected batch, pre-copy, and post-copy validity checks'
! grep -Eq $'^nix-call\t(build|develop|run|store realise)' "${LAST_LOG}" \
  || fail 'hydrate-revalidation: hydration invoked a build or realisation command'
run_case context-bad-equals N fixture "=${opaque#/nix/store/}" reject
run_case context-bad-at N fixture '@/nix/store/44444444444444444444444444444444-at-path' reject

# Hydration recovers a snapshot whose references are missing from the local store but served
# by a configured substituter; unhydratable references still reject fail closed.
run_case hydrate-recoverable E "${recoverable}" '' accept hydrate
run_case hydrate-stale E "${stale}" '' reject hydrate
run_case nix-hydrate-recoverable N "${recoverable}" '' accept hydrate
run_case nix-hydrate-stale N "${stale}" '' reject hydrate

# Missing tools and each external-command failure are fail closed.
run_case absent-nix-store N "${opaque}" '' reject normal "${missing_nix_store_bin}"
run_case sqlite-query-failure N fixture '' reject sqlite-fail
run_case validity-command-failure N "${opaque}" '' reject validity-fail
run_case closure-command-failure N fixture "=${drv#/nix/store/}" reject closure-fail
run_case closure-empty-output N fixture "=${drv#/nix/store/}" reject closure-empty
run_case closure-malformed-output N fixture "=${drv#/nix/store/}" reject closure-malformed
run_case closure-omitted-root N fixture "=${drv#/nix/store/}" reject closure-omit-root

# Duplicate direct/context references are submitted once in one direct validity batch; closure is one
# query and one additional validity batch, independent of reference count.
run_case deduplicated-batches N "${opaque} ${opaque} ${drv}" \
  "${opaque} =${drv#/nix/store/} @${at_path#/nix/store/} @${at_path#/nix/store/}" accept
[ "$(grep -c $'^call\t--check-validity ' "${LAST_LOG}")" -eq 2 ] \
  || fail 'deduplicated-batches: expected one direct and one closure validity invocation'
[ "$(grep -c $'^call\t--query --requisites ' "${LAST_LOG}")" -eq 1 ] \
  || fail 'deduplicated-batches: expected one closure query invocation'
direct_args="$(grep $'^validity-paths\t' "${LAST_LOG}" | sed -n '1p' | cut -f2-)"
closure_args="$(grep $'^validity-paths\t' "${LAST_LOG}" | sed -n '2p' | cut -f2-)"
closure_query_args="$(grep $'^call\t--query --requisites ' "${LAST_LOG}" | sed -n '1p')"
closure_query_args="${closure_query_args#*$'--requisites '}"
[ "$(printf '%s\n' ${direct_args} | sort)" = "$(printf '%s\n' "${opaque}" "${drv}" "${at_path}" | sort)" ] \
  || fail 'deduplicated-batches: direct validity arguments differ from exact expected set'
[ "$(printf '%s\n' ${direct_args} | wc -l | tr -d ' ')" -eq 3 ] \
  || fail 'deduplicated-batches: direct validity argument count was not exactly three'
[ "$(printf '%s\n' ${closure_args} | sort)" = "$(printf '%s\n' "${drv}" "${requisite}" | sort)" ] \
  || fail 'deduplicated-batches: closure validity arguments differ from exact expected set'
[ "$(printf '%s\n' ${closure_args} | wc -l | tr -d ' ')" -eq 2 ] \
  || fail 'deduplicated-batches: closure validity argument count was not exactly two'
[ "${closure_query_args}" = "${drv}" ] \
  || fail 'deduplicated-batches: closure query arguments differ from exact expected set'
[ "$(printf '%s\n' ${closure_query_args} | wc -l | tr -d ' ')" -eq 1 ] \
  || fail 'deduplicated-batches: closure query argument count was not exactly one'

# More than one validity batch remains bounded, and every unique path is submitted exactly once.
batch_paths=''
for index in $(seq 1 129); do
  batch_path="$(printf '/nix/store/77777777777777777777777777777777-batch-%03d' "${index}")"
  batch_paths="${batch_paths}${batch_paths:+ }${batch_path}"
  valid_set="${valid_set}:${batch_path}"
done
run_case bounded-validity-batches N "${batch_paths}" '' accept
batch_invocations=0
while IFS= read -r validity_line; do
  validity_args="${validity_line#*$'\t'}"
  set -- ${validity_args}
  [ "$#" -le 128 ] \
    || fail 'bounded-validity-batches: validity invocation exceeded 128 path arguments'
  batch_invocations=$((batch_invocations + 1))
done < <(grep $'^validity-paths\t' "${LAST_LOG}")
[ "${batch_invocations}" -eq 2 ] \
  || fail 'bounded-validity-batches: 129 paths did not use exactly two validity invocations'
actual_batch_paths="$(grep $'^validity-paths\t' "${LAST_LOG}" | cut -f2- | tr ' ' '\n' | sort)"
expected_batch_paths="$(printf '%s\n' ${batch_paths} | sort)"
[ "${actual_batch_paths}" = "${expected_batch_paths}" ] \
  || fail 'bounded-validity-batches: submitted paths differ from exact expected set'
[ "$(printf '%s\n' "${actual_batch_paths}" | wc -l | tr -d ' ')" -eq 129 ] \
  || fail 'bounded-validity-batches: submitted path argument count was not exactly 129'

# One invalid Nix candidate cannot prevent a valid sibling from installing.
case_dir="${work}/sibling-isolation"
staging="${case_dir}/staging"
home="${case_dir}/home"
mkdir -p "${staging}/nix-eval-cache-v6" "${home}/.cache/nix/eval-cache-v6" "${case_dir}/live"
for name in rejected accepted; do
  path="${staging}/nix-eval-cache-v6/${name}.sqlite"
  reference="${stale}"
  [ "${name}" != accepted ] || reference="${opaque}"
  "${sqlite3_path}" "${path}" \
    "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('${reference}', NULL);"
done
rejected="${staging}/nix-eval-cache-v6/rejected.sqlite"
accepted="${staging}/nix-eval-cache-v6/accepted.sqlite"
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":null,"nixEvalFiles":[{"name":"rejected.sqlite","sha256":"%s","bytes":%s},{"name":"accepted.sqlite","sha256":"%s","bytes":%s}]}' \
  "${key}" "$(sha "${rejected}")" "$(bytes "${rejected}")" \
  "$(sha "${accepted}")" "$(bytes "${accepted}")" >"${staging}/manifest.json"
printf 'rejected-sentinel' >"${home}/.cache/nix/eval-cache-v6/rejected.sqlite"
: >"${case_dir}/output"; : >"${case_dir}/commands"
PATH="${work}/bin:${PATH}" HOME="${home}" STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" LIVE_DB="${case_dir}/live/nix-eval-cache.db" \
SQLITE3_PATH="${sqlite3_path}" EXPECTED_KEY="${key}" DEVENV_VERSION='test-version' \
CACHE_EVAL='false' CACHE_NIX_EVAL='true' GITHUB_OUTPUT="${case_dir}/output" \
MOCK_LOG="${case_dir}/commands" MOCK_MODE=normal MOCK_VALID_SET="${valid_set}" \
  bash "${root}/restore-eval-cache.sh"
[ "$(cat "${home}/.cache/nix/eval-cache-v6/rejected.sqlite")" = rejected-sentinel ] \
  || fail 'sibling-isolation: rejected destination changed'
[ "$(${sqlite3_path} "${home}/.cache/nix/eval-cache-v6/accepted.sqlite" 'PRAGMA quick_check;' | tr -d '\n')" = ok ] \
  || fail 'sibling-isolation: valid sibling was not installed'
grep -qx 'nix-eval-files-restored=1' "${case_dir}/output" \
  || fail 'sibling-isolation: wrong restored count'

echo 'restore-context-matrix: OK'
