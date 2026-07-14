# account_usage_fast

Reusable multi-tenant SQL cost & chargeback toolkit for Databricks ISVs.
Driven entirely by Unity Catalog system tables. No hard-coded rates or IDs.

## Repo structure

```
Databricks Operating Cost Dashboard.lvdash.json   # AI/BI Lakeview dashboard
README.md
sql/
  01_warehouse_cost.sql          # Warehouse cost by SKU, type, time
  02_tenant_cost_by_tag.sql      # Tenant cost via custom_tags['tenant'] (Pattern 1)
  03_tenant_cost_query_share.sql # Tenant cost via query compute-time share (Pattern 2)
  04_cost_per_query_core.sql     # Core per-query cost output (one row per statement)
  05_query_statement_detail.sql  # Query Statement Detail visual (dashboard page 6)
  06_untagged_spend.sql          # Tagging-hygiene / unattributable spend
  07_serverless_vs_classic.sql   # Serverless vs Pro/Classic idle-cost comparison
mapping/
  tenant_mapping_ddl.sql         # Mapping table DDL (principal → tenant)
  tenant_resolver_view.sql       # Resolver view (3-tier: tag > mapping > identity)
  validation_self_check.sql      # Reconciliation & self-check queries
```

## Dashboard pages

| Page | Description |
|---|---|
| Cost Overview | Total spend by day/SKU, 7-day MA, AI forecast |
| Cost by Tenant | Tagged vs untagged cost, top-10 tenants, trend |
| Global Filters | Shared date-range + time-grain filters |
| Workspace Segmentation | Cost & DBUs by workspace and product |
| Warehouse Monitoring | Per-warehouse cost, query stats, sizing flags |
| Cost per Query | Query Statement Detail: top-N, discount-adjusted, inline HTML data-bars |

## System table grants required

Run as an account admin or metastore admin before using this toolkit:

```sql
GRANT SELECT ON system.billing.usage          TO `<group-or-sp>`;
GRANT SELECT ON system.billing.list_prices    TO `<group-or-sp>`;
GRANT SELECT ON system.query.history          TO `<group-or-sp>`;
GRANT SELECT ON system.compute.warehouses     TO `<group-or-sp>`;
GRANT SELECT ON system.access.workspaces_latest TO `<group-or-sp>`;
```

For workspace-level access (if system tables are in a separate account catalog):
```sql
GRANT USE CATALOG ON system TO `<group-or-sp>`;
GRANT USE SCHEMA  ON system.billing  TO `<group-or-sp>`;
GRANT USE SCHEMA  ON system.query    TO `<group-or-sp>`;
GRANT USE SCHEMA  ON system.compute  TO `<group-or-sp>`;
GRANT USE SCHEMA  ON system.access   TO `<group-or-sp>`;
```

## Dashboard parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `:time_range` | Date range | Last 30 days | Filters all datasets |
| `:param_time_key` | Select | Day | Time grain: Day / Week / Month / Quarter / Year |
| `:warehouse_id` | Multi-select | all | Warehouse ID filter |
| `:warehouse_name` | Multi-select | all | Friendly warehouse name filter |
| `:workspace_id` | Multi-select | all | Workspace ID filter |
| `:tenant_key` | Multi-select | all | Tenant key filter (Cost per Query page) |
| `:statement_id` | Multi-select | all | Statement ID filter (Cost per Query page) |
| `:dbsql_discount` | Float | 0 | Effective-rate discount 0–1 (0 = list price) |
| `:top_n` | Int or 'all' | 25 | Top-N rows in Query Statement Detail |
| `:top_n_dimension` | Select | Statement Id | Dimension for top-N ranking |
| `:group_key` | Select | Warehouse Name | Grouping dimension |
| `:date_agg_level` | Select | DAY | Time aggregation: HOUR or DAY |
| `:instance_rate_per_hr` | Float | 0 | VM $/node-hour for Classic/Pro idle cost |
| `:top_n_tenants` | Int | 10 | Max tenants shown before grouping into 'Other' |

## Cost model

**DBU cost** = `usage_quantity × list_prices.pricing.effective_list.default`
Never hard-coded; always joined to `system.billing.list_prices` (current rate = `price_end_time IS NULL`).

**Effective rate override**: set `:dbsql_discount` to your post-commit discount fraction
(e.g. 0.15 for 15% discount). Applied as `dollar_cost * (1 - discount)` in
`05_query_statement_detail.sql`.

**Per-query attribution (compute-time share)**:
```
query_cost = (query_total_task_duration_ms / warehouse_hour_total_ms) * warehouse_hour_cost
```
Joins `system.billing.usage` to `system.query.history` at hourly granularity via
`DATE_TRUNC('HOUR', usage_end_time) = DATE_TRUNC('HOUR', query.start_time)`.

**Tenant key resolution (three tiers)**:
1. `custom_tags['tenant']` on billing usage (highest priority)
2. `identity_metadata.run_as` → `tenant_key_mapping` table (requires `mapping/` setup)
3. Raw `identity_metadata.run_as` / `executed_by` (fallback)

## Tenant mapping setup (Pattern 2 attribution)

1. Run `mapping/tenant_mapping_ddl.sql` (replace `<catalog>.<schema>`).
2. INSERT rows for each service principal / user → tenant relationship.
3. Run `mapping/tenant_resolver_view.sql` to create the resolver view.
4. Uncomment the mapping join lines in `sql/03_*` and `sql/04_*`.
5. Run `mapping/validation_self_check.sql` to verify coverage.

## Serverless vs Classic/Pro idle cost

Run `sql/07_serverless_vs_classic.sql` with `:instance_rate_per_hr` set to your
cloud/region on-demand rate to see side-by-side total cost including idle VM hours.
Serverless shows 0 idle VM cost because it scales to zero between queries.

## Validation

After any configuration change, run the three checks in `mapping/validation_self_check.sql`:
- **CHECK 1**: `billing_total` vs sum of allocated tenant cost should differ by <1%.
- **CHECK 2**: `UNATTRIBUTABLE` rows in the tagging-hygiene breakdown should trend to 0%.
- **CHECK 3**: Orphaned query count should be near 0 for well-configured warehouses.
- **CHECK 4**: `QUERY_TAG` share of queries should increase as tags are deployed.

## Working in this repo

* Edit the dashboard in Databricks; commit the resulting `.lvdash.json`.
* Review diffs before committing — dashboard JSON can be large.
* SQL files in `sql/` and `mapping/` are the canonical query definitions;
  dashboard datasets are derived from them (not the reverse).
* Do not commit real customer identifiers in `tenant_mapping_ddl.sql`.
