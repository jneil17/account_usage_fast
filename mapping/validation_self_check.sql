-- =============================================================================
-- mapping/validation_self_check.sql
-- Reconciliation and self-check queries.
-- Run after initial setup to verify the cost model and attribution coverage.
--
-- CHECK 1: Total billing cost vs total allocated tenant cost (must ≈ 100%)
-- CHECK 2: Tagging-hygiene breakdown (resolution_method distribution)
-- CHECK 3: Orphaned queries (queries with no matching billing hour)
-- CHECK 4: Per-tenant query attribution completeness
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CHECK 1: Total SQL warehouse cost from billing (the ground truth)
-- Compare this to the SUM of allocated cost from 03_tenant_cost_query_share
-- for the same period. Delta should be <1% (rounding from fractional compute_ms).
-- ---------------------------------------------------------------------------
SELECT 'billing_total_sql_warehouses' AS check_label,
  ROUND(SUM(u.usage_quantity *
    try_variant_get(to_variant_object(p.pricing), '$.effective_list.default', 'decimal(38,18)')
  ), 2) AS cost_usd
FROM system.billing.usage u
JOIN system.billing.list_prices p
  ON u.sku_name = p.sku_name
  AND u.usage_unit = p.usage_unit
  AND p.price_end_time IS NULL          -- current rate
WHERE u.usage_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
  AND u.billing_origin_product = 'SQL'
  AND u.usage_metadata.warehouse_id IS NOT NULL;


-- ---------------------------------------------------------------------------
-- CHECK 2: Tagging-hygiene distribution over the last 30 days
-- Goal: 'TAG' row should approach 100% as tagging coverage improves.
-- 'UNATTRIBUTABLE' must be eliminated before tenant cost allocation is reliable.
-- ---------------------------------------------------------------------------
SELECT
  CASE
    WHEN custom_tags['tenant'] IS NOT NULL    THEN 'TAG'
    WHEN identity_metadata.run_as IS NOT NULL THEN 'IDENTITY_FALLBACK'
    ELSE 'UNATTRIBUTABLE'
  END                                                 AS resolution_status,
  COUNT(*)                                            AS row_count,
  ROUND(SUM(usage_quantity), 2)                       AS total_dbus,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct_rows
FROM system.billing.usage
WHERE usage_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- CHECK 3: Orphaned queries — queries that ran on a warehouse but have no
-- matching billing hour. These queries cannot receive cost attribution.
-- Common cause: queries ran during a warehouse hour that wasn't billed
-- (e.g., Serverless sub-second slots or clock skew).
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS orphaned_query_count
FROM system.query.history q
LEFT JOIN (
  SELECT DISTINCT
    usage_metadata.warehouse_id                   AS warehouse_id,
    DATE_TRUNC('HOUR', usage_end_time)            AS usage_hour
  FROM system.billing.usage
  WHERE usage_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
    AND billing_origin_product = 'SQL'
    AND usage_metadata.warehouse_id IS NOT NULL
) b ON q.compute.warehouse_id = b.warehouse_id
    AND DATE_TRUNC('HOUR', q.start_time) = b.usage_hour
WHERE CAST(q.start_time AS DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
  AND q.compute.warehouse_id IS NOT NULL
  AND b.warehouse_id IS NULL;  -- no matching billing hour


-- ---------------------------------------------------------------------------
-- CHECK 4: Per-tenant attribution completeness
-- Rows where tenant_key falls back to executed_by (not from a tag/mapping)
-- indicate attribution gaps. Add those principals to tenant_key_mapping.
-- ---------------------------------------------------------------------------
SELECT
  CASE WHEN query_tags['tenant'] IS NOT NULL THEN 'QUERY_TAG' ELSE 'FALLBACK_IDENTITY' END AS resolution,
  COUNT(*)                                             AS query_count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct_queries
FROM system.query.history
WHERE CAST(start_time AS DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
  AND compute.warehouse_id IS NOT NULL
  AND execution_status = 'FINISHED'
GROUP BY 1
ORDER BY 1;
