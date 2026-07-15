#!/usr/bin/env bash
# =============================================================================
# provision_warehouses.sh — create the 4 demo SQL warehouses for the harness.
#
#   Method A (warehouse-per-tenant, attribution via custom_tags['tenant']):
#     - "Carls Corner"          tag tenant="Carls Corner"
#     - "Tims Trailers"         tag tenant="Tims Trailers"
#     - "Jefferies Jobs"        tag tenant="Jefferies Jobs"
#   Method B (shared warehouse, attribution via query_tags['tenant']):
#     - "Shared - Multi-Tenant" tag tenant="shared"
#
# ALL warehouses: Serverless (PRO), 2X-Small, 1-minute auto-stop. SERVERLESS ONLY.
#
# Idempotent-friendly: if a warehouse with the target name already exists it is
# REUSED (not duplicated). Writes the 4 ids + host to ./warehouses.env, which
# generate_load.py and teardown.sh read.
#
# Usage:  ./provision_warehouses.sh <cli_profile>
#         PROFILE=<cli_profile> ./provision_warehouses.sh
# =============================================================================
set -uo pipefail

PROFILE="${1:-${PROFILE:-}}"
[ -z "${PROFILE}" ] && { echo "Usage: ./provision_warehouses.sh <cli_profile>"; exit 1; }
DBX="databricks --profile ${PROFILE}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/warehouses.env"

HOST=$(${DBX} api get /api/2.0/preview/scim/v2/Me >/dev/null 2>&1; \
       python3 -c "import configparser,os; c=configparser.ConfigParser(); c.read(os.path.expanduser('~/.databrickscfg')); print(c['${PROFILE}']['host'].replace('https://','').rstrip('/'))" 2>/dev/null)
[ -z "${HOST}" ] && { echo "Could not resolve host for profile ${PROFILE}"; exit 1; }

# find_or_create <name> <tenant_tag>  -> echoes warehouse id
find_or_create () {
  local NAME="$1" TENANT="$2" existing
  existing=$(${DBX} warehouses list -o json 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(next((w['id'] for w in d if w['name']==sys.argv[1]),''))" "${NAME}")
  if [ -n "${existing}" ]; then
    echo "${existing}"; return
  fi
  ${DBX} api post /api/2.0/sql/warehouses --json "$(python3 -c '
import json,sys
name,tenant=sys.argv[1],sys.argv[2]
print(json.dumps({
 "name":name,"cluster_size":"2X-Small","auto_stop_mins":1,
 "min_num_clusters":1,"max_num_clusters":1,
 "enable_serverless_compute":True,"warehouse_type":"PRO","enable_photon":True,
 "spot_instance_policy":"COST_OPTIMIZED",
 "tags":{"custom_tags":[{"key":"tenant","value":tenant}]}
}))' "${NAME}" "${TENANT}")" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'
}

echo "Provisioning Serverless 2X-Small warehouses on ${HOST} (profile ${PROFILE})..."
CARLS_WH=$(find_or_create "Carls Corner"          "Carls Corner")
TIMS_WH=$(find_or_create  "Tims Trailers"         "Tims Trailers")
JEFF_WH=$(find_or_create  "Jefferies Jobs"        "Jefferies Jobs")
SHARED_WH=$(find_or_create "Shared - Multi-Tenant" "shared")

cat > "${ENV_FILE}" <<EOF
# written by provision_warehouses.sh — read by generate_load.py and teardown.sh
PROFILE=${PROFILE}
HOST=${HOST}
CARLS_WH=${CARLS_WH}
TIMS_WH=${TIMS_WH}
JEFF_WH=${JEFF_WH}
SHARED_WH=${SHARED_WH}
EOF

echo "Wrote ${ENV_FILE}:"
cat "${ENV_FILE}"
echo "Warehouses ready. Next: python3 generate_load.py --profile ${PROFILE}"
