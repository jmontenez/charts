#!/usr/bin/env bash
#
# db-migrator controller (mode b). Runs as an ArgoCD PreSync hook, in-cluster.
# 1. discovers tenants from ham (GET api/v1/tenants, internal port, no auth, paginated);
# 2. fans out one child migration Job per tenant (from /scripts/job.tpl.yaml, which is
#    rendered by the `liquibase` library — Vault creds per tenant via vault-env);
# 3. by batch (BATCH_SIZE concurrent child Jobs), isolating per-tenant failures;
# 4. exits non-zero only if the failure rate exceeds FAIL_THRESHOLD_PCT (blocks the Sync).
#
set -uo pipefail

HAM_BASE_URL="${HAM_BASE_URL:?}"; HAM_PAGE_SIZE="${HAM_PAGE_SIZE:-200}"
HAM_STATUS_INCLUDE="${HAM_STATUS_INCLUDE:-}"
NAMESPACE="${NAMESPACE:?}"; CHILD_TPL="${CHILD_TPL:-/scripts/job.tpl.yaml}"
RUN_ID="${RUN_ID:?}"; BATCH_SIZE="${BATCH_SIZE:-25}"
FAIL_THRESHOLD_PCT="${FAIL_THRESHOLD_PCT:-10}"; JOB_TIMEOUT="${JOB_TIMEOUT:-600}"

RESULT_DIR="$(mktemp -d)/r"; mkdir -p "$RESULT_DIR"
log() { echo "[db-migrator] $*" >&2; }

ensure_tools() {
  for b in curl jq envsubst kubectl; do command -v "$b" >/dev/null 2>&1 || MISSING=1; done
  [ -z "${MISSING:-}" ] && return 0
  if command -v apk >/dev/null 2>&1; then apk add --no-cache curl jq gettext >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl jq gettext-base >/dev/null 2>&1 || true; fi
  for b in curl jq envsubst kubectl; do command -v "$b" >/dev/null 2>&1 || { log "FATAL: $b missing"; exit 2; }; done
}

discover_tenants() {
  local page=0 resp re=""
  [ -n "$HAM_STATUS_INCLUDE" ] && re="$(echo "$HAM_STATUS_INCLUDE" | tr ',' '|')"
  while : ; do
    resp="$(curl -sS -m 30 -H 'Accept: application/json' \
      "${HAM_BASE_URL}/api/v1/tenants?PageIndex=${page}&PageSize=${HAM_PAGE_SIZE}")" \
      || { log "FATAL: ham call failed"; exit 3; }
    if [ -n "$re" ]; then
      echo "$resp" | jq -r --arg re "$re" '.items[] | select(.statutTenantCode|test("^("+$re+")$")) | .namespace'
    else
      echo "$resp" | jq -r '.items[].namespace'
    fi
    [ "$(echo "$resp" | jq -r '.hasNextPage // false')" = "true" ] || break
    page=$((page+1))
  done | sed '/^$/d' | sort -u
}

migrate_one() {
  local t="$1" job="migrate-${1}-${RUN_ID}"
  kubectl -n "$NAMESPACE" delete job "$job" --ignore-not-found --wait=false >/dev/null 2>&1
  # shellcheck disable=SC2016  # ${...} is the envsubst whitelist, not to be expanded here
  if ! TENANT="$t" envsubst '${TENANT} ${RUN_ID}' < "$CHILD_TPL" \
        | kubectl -n "$NAMESPACE" apply -f - >/dev/null 2>"$RESULT_DIR/$t.err"; then
    echo "apply failed: $(tr '\n' ' ' <"$RESULT_DIR/$t.err")" >"$RESULT_DIR/$t.msg"; echo FAIL >"$RESULT_DIR/$t.status"; return
  fi
  if kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout="${JOB_TIMEOUT}s" >/dev/null 2>&1; then
    echo PASS >"$RESULT_DIR/$t.status"
  else
    kubectl -n "$NAMESPACE" logs "job/$job" --tail=40 >"$RESULT_DIR/$t.log" 2>/dev/null || true
    echo "timeout or failed (${JOB_TIMEOUT}s)" >"$RESULT_DIR/$t.msg"; echo FAIL >"$RESULT_DIR/$t.status"
  fi
}

ensure_tools
mapfile -t TENANTS < <(discover_tenants)
n="${#TENANTS[@]}"
[ "$n" -eq 0 ] && { log "FATAL: no tenants from ham"; exit 4; }
log "migrating ${n} tenant(s), batch=${BATCH_SIZE}, threshold=${FAIL_THRESHOLD_PCT}%"

i=0
while [ "$i" -lt "$n" ]; do
  for t in "${TENANTS[@]:i:BATCH_SIZE}"; do migrate_one "$t" & done
  wait
  i=$((i+BATCH_SIZE))
done

passed=0 failed=0
for t in "${TENANTS[@]}"; do
  if [ "$(cat "$RESULT_DIR/$t.status" 2>/dev/null)" = PASS ]; then passed=$((passed+1))
  else failed=$((failed+1)); log "KO ${t}: $(cat "$RESULT_DIR/$t.msg" 2>/dev/null)"; fi
done
pct=$(( failed * 100 / n ))
log "RESULT: ${passed} OK / ${failed} KO / ${n} (fail ${pct}%, threshold ${FAIL_THRESHOLD_PCT}%)"
if [ "$pct" -gt "$FAIL_THRESHOLD_PCT" ]; then log "THRESHOLD EXCEEDED -> block Sync"; exit 1; fi
log "under threshold -> Sync may proceed"; exit 0
