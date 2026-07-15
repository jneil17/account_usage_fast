# `data_generation/` — tagging + system-table data-generation harness

**This folder is how you tag + generate data for the system tables.**

It is a **test / demo harness**. It provisions tagged Serverless SQL warehouses
and runs synthetic query load so that per-tenant SQL usage shows up in the
Databricks **system tables** — `system.billing.usage` and
`system.query.history` — which the *Databricks Operating Cost* dashboard (repo
root) reads. Run it in your own workspace to exercise the chargeback dashboard
with realistic, uneven per-tenant usage.

> ⚠️ **Not production.** This generates synthetic usage to test/demo the
> dashboard. It does not model a real workload and is not meant to run on a
> schedule in production.

## The two attribution methods it demonstrates

| Method | Warehouse layout | Tenant key | Where it lands |
|---|---|---|---|
| **A — warehouse-per-tenant** | one warehouse per tenant | warehouse `custom_tags['tenant']` = tenant name | `system.billing.usage.custom_tags['tenant']` |
| **B — shared warehouse** | one shared warehouse for all tenants | per-query `query_tags['tenant']`, set with `SET QUERY_TAGS['tenant']='<name>'` in a persistent session | `system.query.history.query_tags['tenant']` |

Attribution here is **purely tag-driven** — Method A via `custom_tags`, Method B
via `query_tags`. The harness does **not** require the `tenant_key_mapping`
table in `../mapping/`. That table + the `v_tenant_key_resolver` view remain as
the documented service-principal *fallback* reference for environments where
per-query tagging is not feasible; they are not used by this harness.

### Why a persistent session for Method B
`SET QUERY_TAGS['tenant']=...` is a **session** setting. The Databricks SQL
Statement Execution API is stateless per call, so a `SET` in one call does not
carry to the next. The load generator therefore uses the
`databricks-sql-connector`, opening **one connection per tenant**, issuing the
`SET`, then running that tenant's queries on the same session so the tag sticks.

## Prerequisites

- **Databricks CLI** configured with a profile for your workspace
  (`databricks auth login --host <host> --profile <profile>`), Valid.
- **Serverless SQL** enabled in the workspace (this harness is serverless-only).
- Python 3 with the connector: `pip install databricks-sql-connector`.
- Read access to the `samples` catalog. The load targets
  **`samples.bakehouse.sales_customers`** (present in essentially every
  workspace). If your workspace exposes a different bakehouse table, point
  `TABLE` in `generate_load.py` at another `samples.bakehouse.*` table.
- Permission to create SQL warehouses.

## Files

| File | Purpose |
|---|---|
| `provision_warehouses.sh` | Create 4 Serverless 2X-Small warehouses (1-min auto-stop): 3 per-tenant (Method A, tagged `custom_tags['tenant']`) + 1 `Shared - Multi-Tenant` (Method B). Reuses by name if they already exist. Writes `warehouses.env`. |
| `generate_load.py` | Run UNEVEN per-tenant query volumes against `samples.bakehouse.sales_customers`. Method A drives each per-tenant warehouse; Method B drives the shared warehouse with `SET QUERY_TAGS['tenant']` per persistent session. All tenant names, counts, warehouse ids, and the CLI profile are parameterized. |
| `teardown.sh` | Idempotent: delete the 4 warehouses and remove `warehouses.env`. |
| `warehouses.env` | *(generated)* warehouse ids + host, shared between the scripts. Not committed. |

## How to run

```bash
cd data_generation

# 1. Provision the 4 serverless warehouses (writes warehouses.env)
./provision_warehouses.sh <your_cli_profile>

# 2. Generate uneven tagged load (both methods). Defaults:
#    Method A  Carls 40 / Tims 20 / Jefferies 8
#    Method B  Carls 25 / Tims 15 / Jefferies 6   (Carls heaviest -> Jefferies lightest)
python3 generate_load.py --profile <your_cli_profile>

#    Method A or B only, or override counts / tenant names / warehouse ids:
python3 generate_load.py --profile <p> --method A
python3 generate_load.py --profile <p> --carls-a 60 --carls-b 30
python3 generate_load.py --profile <p> --carls-name "Acme Co" --carls-wh <id> ...

# 3. Verify in the system tables (query.history ingests in ~10-15 min):
#    Method A — counts by warehouse; Method B — counts by query_tags['tenant'].

# 4. Tear down when finished
./teardown.sh <your_cli_profile>
```

## Verifying the data landed

Query history is near-real-time (~10–15 min lag); billing usage lags several
hours. To confirm the query side quickly:

```sql
-- Method A: counts by warehouse (no per-query tag by design)
-- Method B: counts by query_tags['tenant'] on the shared warehouse
SELECT compute.warehouse_id, query_tags['tenant'] AS tenant_tag, COUNT(*) queries
FROM system.query.history
WHERE CAST(start_time AS DATE) = current_date()
  AND statement_text NOT LIKE 'SET %'
GROUP BY 1, 2 ORDER BY 1, queries DESC;
```

Once billing ingests (a couple of hours), the dashboard's Cost-by-Tenant panels
populate: Method A from `custom_tags['tenant']`, Method B from the query-share
allocation keyed on `query_tags['tenant']`.
