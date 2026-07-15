#!/usr/bin/env bash
# =============================================================================
# teardown.sh — idempotent teardown for the data-generation harness.
#
# Deletes the 4 warehouses this harness created (Carls / Tims / Jefferies /
# Shared - Multi-Tenant) and removes the generated warehouses.env.
#
# The harness ONLY creates warehouses (load generation just queries the
# read-only samples.* datasets), so there are no catalogs/schemas/tables to
# drop here. Safe to run multiple times.
#
# Warehouse ids are read from ./warehouses.env if present; otherwise the four
# warehouses are located by name.
#
# Usage:  ./teardown.sh [<cli_profile>]
#         (profile falls back to PROFILE in warehouses.env, then $PROFILE env)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/warehouses.env"

# load env file if present
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"

PROFILE="${1:-${PROFILE:-}}"
[ -z "${PROFILE}" ] && { echo "Usage: ./teardown.sh <cli_profile>  (or set PROFILE / run provision first)"; exit 1; }
DBX="databricks --profile ${PROFILE}"

echo "=== data-generation harness teardown (profile ${PROFILE}) ==="

# Resolve ids: prefer warehouses.env, else look up by name.
resolve_by_name () {
  ${DBX} warehouses list -o json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(next((w['id'] for w in d if w['name']==sys.argv[1]),''))" "$1"
}
CARLS_WH="${CARLS_WH:-$(resolve_by_name 'Carls Corner')}"
TIMS_WH="${TIMS_WH:-$(resolve_by_name 'Tims Trailers')}"
JEFF_WH="${JEFF_WH:-$(resolve_by_name 'Jefferies Jobs')}"
SHARED_WH="${SHARED_WH:-$(resolve_by_name 'Shared - Multi-Tenant')}"

for id in "${CARLS_WH}" "${TIMS_WH}" "${JEFF_WH}" "${SHARED_WH}"; do
  [ -z "${id}" ] && continue
  echo "-- deleting warehouse ${id}"
  ${DBX} warehouses delete "${id}" >/dev/null 2>&1 \
    && echo "   deleted" \
    || echo "   (already gone / not found — skipped)"
done

if [ -f "${ENV_FILE}" ]; then
  rm -f "${ENV_FILE}" && echo "-- removed ${ENV_FILE}"
fi

echo "=== teardown complete (nothing idles: all warehouses had auto_stop_mins=1) ==="
