-- =============================================================================
-- mapping/tenant_mapping_ddl.sql
-- Tenant key mapping table DDL.
-- Maps Databricks principals (service principals, users, groups) to tenant
-- identifiers for cost chargeback. Required for Pattern 2 attribution (query-
-- share allocation) when compute is not warehouse-per-tenant.
--
-- SETUP:
--   1. Replace <catalog>.<schema> with your target catalog and schema.
--   2. Run this script once to create the table.
--   3. INSERT rows for each principal-to-tenant relationship.
--   4. UNCOMMENT the mapping join in 03_tenant_cost_query_share.sql and
--      04_cost_per_query_core.sql.
--
-- Handling tenant changes over time:
--   Set effective_to on the old row and INSERT a new row with the new tenant.
--   Queries filter WHERE effective_to IS NULL OR effective_to > CURRENT_DATE.
-- =============================================================================

CREATE TABLE IF NOT EXISTS <catalog>.<schema>.tenant_key_mapping (
  principal_name   STRING NOT NULL COMMENT 'Databricks service principal application ID, user email, or group display name',
  principal_type   STRING NOT NULL COMMENT 'SP | USER | GROUP',
  tenant_id        STRING NOT NULL COMMENT 'Tenant identifier for chargeback (e.g. customer UUID or short slug)',
  tenant_name      STRING          COMMENT 'Human-readable tenant / customer name',
  effective_from   DATE   NOT NULL COMMENT 'Mapping active from this date (inclusive)',
  effective_to     DATE            COMMENT 'Mapping expires after this date (exclusive). NULL = currently active',
  notes            STRING          COMMENT 'Free-text context'
)
USING DELTA
COMMENT 'Principal-to-tenant mapping for SQL warehouse cost chargeback. One row per principal per active period.'
TBLPROPERTIES (
  'delta.autoOptimize.optimizeWrite' = 'true',
  'delta.autoOptimize.autoCompact'   = 'true'
);

-- ---------------------------------------------------------------------------
-- Sample rows (replace with real data; never commit real customer identifiers)
-- ---------------------------------------------------------------------------
INSERT INTO <catalog>.<schema>.tenant_key_mapping VALUES
  -- Service principals (Entra group pattern: client-<tenant_id>)
  ('app-sp-tenant-a@example.com',  'SP',   'tenant-a', 'Tenant A (placeholder)', DATE'2024-01-01', NULL,             'example placeholder'),
  ('app-sp-tenant-b@example.com',  'SP',   'tenant-b', 'Tenant B (placeholder)', DATE'2024-01-01', NULL,             'example placeholder'),
  -- Direct user attribution
  ('analyst@example.com',          'USER', 'internal', 'Internal / Ops',          DATE'2024-01-01', NULL,             'example placeholder'),
  -- Historical mapping (tenant migrated from A to C)
  ('app-sp-migrated@example.com',  'SP',   'tenant-a', 'Tenant A (historical)',   DATE'2023-01-01', DATE'2024-01-01', 'migrated to tenant-c'),
  ('app-sp-migrated@example.com',  'SP',   'tenant-c', 'Tenant C',                DATE'2024-01-01', NULL,             'post-migration');

-- ---------------------------------------------------------------------------
-- Verification query: confirm all expected principals have an active mapping
-- ---------------------------------------------------------------------------
-- SELECT principal_name, tenant_id, effective_from, effective_to
-- FROM <catalog>.<schema>.tenant_key_mapping
-- WHERE effective_to IS NULL OR effective_to > CURRENT_DATE
-- ORDER BY tenant_id, principal_name;
