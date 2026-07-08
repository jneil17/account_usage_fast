# account_usage_fast

This repo contains the Lakeview source for the Databricks Operating Cost Dashboard, a cost-monitoring dashboard for a multi-tenant ISV environment moving toward volume-based pricing.

## Included asset

* `Databricks Operating Cost Dashboard.lvdash.json` — Lakeview dashboard definition tracked in Git.

## Dashboard coverage

The dashboard is organized into five main pages:

* Cost Overview
* Cost by Tenant
* Global Filters
* Workspace Segmentation
* Warehouse Monitoring

## Data sources

The dashboard queries Databricks system tables, primarily:

* `system.billing.usage`
* `system.billing.list_prices`
* `system.query.history`
* `system.compute.warehouses`
* `system.access.workspaces_latest`

## Key modeling choices

* Costs are priced in USD using effective list prices from `system.billing.list_prices`.
* Tenant attribution prefers `custom_tags['tenant']`; untagged usage can be analyzed separately.
* Time grain is parameterized so views can roll up by day, week, month, quarter, or year.
* Warehouse monitoring focuses on SQL warehouse cost, concurrency, and queue-time behavior.

## Working in this repo

* Edit the dashboard in Databricks and let the Git folder track the resulting `.lvdash.json` changes.
* Review Git diffs before committing because dashboard JSON exports can be large.
* Keep supporting docs in this repo lightweight and focused on dashboard purpose and data lineage.

## Notes

This repo currently tracks a single dashboard asset plus lightweight repository metadata (`README.md`, `.gitignore`). If you add related queries, notebooks, or test data, document them here so the repo stays easy to navigate.
