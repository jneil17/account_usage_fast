-- =============================================================================
-- mapping/tenant_resolver_view.sql
-- Tenant key resolver view for billing usage rows.
-- Applies a three-tier resolution:
--   1. custom_tags['tenant']        — explicit tag (highest priority, zero ambiguity)
--   2. identity_metadata.run_as     — matched via tenant_key_mapping table
--   3. identity_metadata.run_as     — raw identity fallback (partial attribution)
--   4. 'Unattributable'             — no tenant key resolvable (dark spend)
--
-- SETUP:
--   1. Replace <catalog>.<schema> with the same location used in
--      tenant_mapping_ddl.sql.
--   2. Run tenant_mapping_ddl.sql first.
--   3. Create this view once; downstream queries join to it instead of
--      repeating the resolution logic.
-- =============================================================================

CREATE OR REPLACE VIEW <catalog>.<schema>.v_tenant_key_resolver
COMMENT 'Resolves the tenant key for every billing usage row. Three-tier priority: (1) custom_tags[tenant], (2) principal mapping, (3) raw identity fallback.'
AS
WITH mapping AS (
  -- Only active mappings (handles historical tenant changes)
  SELECT principal_name, tenant_id, tenant_name
  FROM <catalog>.<schema>.tenant_key_mapping
  WHERE effective_to IS NULL OR effective_to > CURRENT_DATE
)
SELECT
  u.usage_record_id,
  u.workspace_id,
  u.usage_date,
  u.billing_origin_product,
  u.sku_name,
  u.usage_quantity,
  u.usage_unit,
  u.identity_metadata.run_as                                   AS run_as_principal,
  u.custom_tags['tenant']                                      AS tag_tenant,
  m.tenant_id                                                  AS mapped_tenant_id,
  m.tenant_name                                                AS mapped_tenant_name,
  -- Resolved tenant key — USE THIS COLUMN in all chargeback queries
  COALESCE(
    u.custom_tags['tenant'],
    m.tenant_id,
    u.identity_metadata.run_as,
    'Unattributable'
  )                                                            AS tenant_key,
  COALESCE(
    u.custom_tags['tenant'],
    m.tenant_name,
    u.identity_metadata.run_as,
    'Unattributable'
  )                                                            AS tenant_display_name,
  -- Resolution method (use to measure tagging-hygiene progress)
  CASE
    WHEN u.custom_tags['tenant'] IS NOT NULL      THEN 'TAG'
    WHEN m.tenant_id IS NOT NULL                  THEN 'MAPPING'
    WHEN u.identity_metadata.run_as IS NOT NULL   THEN 'FALLBACK_IDENTITY'
    ELSE 'UNATTRIBUTABLE'
  END                                                          AS resolution_method
FROM system.billing.usage u
LEFT JOIN mapping m
  ON u.identity_metadata.run_as = m.principal_name
;

-- ---------------------------------------------------------------------------
-- Quick-check: tagging hygiene summary after creating the view
-- ---------------------------------------------------------------------------
-- SELECT resolution_method,
--   COUNT(*) AS row_count,
--   ROUND(SUM(usage_quantity), 2) AS total_dbus,
--   ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_rows
-- FROM <catalog>.<schema>.v_tenant_key_resolver
-- WHERE usage_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
-- GROUP BY 1 ORDER BY 1;
