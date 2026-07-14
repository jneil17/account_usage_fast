-- =============================================================================
-- 07_serverless_vs_classic.sql
-- Serverless vs Pro/Classic SQL warehouse total-cost comparison.
-- Highlights the idle-cost difference:
--   Classic/Pro: VM cost accrues while the warehouse is running, including
--     idle time before auto-stop. DBU + VM ≈ fully-loaded cost.
--   Serverless: zero cost when idle; DBU only while processing queries.
--
-- OPTIONAL VM cost module (Classic/Pro only):
--   Set :instance_rate_per_hr to your cloud/region on-demand or blended
--   rate (USD/node-hour). Set to 0 to see DBU cost only.
--   Node count defaults (driver + workers):
--     2X-Small=2, X-Small=3, Small=5, Medium=9, Large=17,
--     X-Large=35, 2X-Large=67, 3X-Large=131, 4X-Large=259
--
-- Inputs:
--   :time_range.min / :time_range.max — date range (inclusive, DATE)
--   :warehouse_id                     — array; ['all'] = all warehouses
--   :instance_rate_per_hr             — float; $/node-hour for Classic/Pro (0 = DBU only)
--
-- Output: warehouse-level cost breakdown with idle-cost estimate and
--         Serverless-vs-Classic/Pro comparison flag
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices WHERE currency_code = 'USD'
),
wh_dim AS (
  SELECT warehouse_id, warehouse_name, warehouse_type, warehouse_size,
    CASE warehouse_size
      WHEN '2X-Small' THEN 2  WHEN 'X-Small' THEN 3  WHEN 'Small' THEN 5
      WHEN 'Medium'   THEN 9  WHEN 'Large'   THEN 17  WHEN 'X-Large' THEN 35
      WHEN '2X-Large' THEN 67 WHEN '3X-Large' THEN 131 WHEN '4X-Large' THEN 259
      ELSE 3  -- default X-Small node count
    END AS node_count
  FROM system.compute.warehouses
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) = 1
),
wh_cost AS (
  SELECT
    u.usage_metadata.warehouse_id                         AS warehouse_id,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0))        AS dbu_cost_usd,
    SUM(u.usage_quantity)                                 AS total_dbus,
    -- Distinct billed hours ≈ time warehouse was on
    COUNT(DISTINCT DATE_TRUNC('HOUR', u.usage_end_time))  AS billed_hours
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name
    AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
    AND u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
    AND (array_contains(:warehouse_id, u.usage_metadata.warehouse_id) OR array_contains(:warehouse_id, 'all'))
  GROUP BY 1
),
query_active AS (
  -- Hours that had at least one finished query (denominator for idle estimate)
  SELECT compute.warehouse_id AS warehouse_id,
    COUNT(DISTINCT DATE_TRUNC('HOUR', start_time)) AS active_query_hours
  FROM system.query.history
  WHERE CAST(start_time AS DATE) BETWEEN :time_range.min AND :time_range.max
    AND compute.warehouse_id IS NOT NULL
    AND execution_status = 'FINISHED'
    AND (array_contains(:warehouse_id, compute.warehouse_id) OR array_contains(:warehouse_id, 'all'))
  GROUP BY 1
)
SELECT
  wc.warehouse_id,
  COALESCE(wd.warehouse_name, wc.warehouse_id)              AS warehouse_name,
  COALESCE(wd.warehouse_type, 'Unknown')                    AS warehouse_type,
  COALESCE(wd.warehouse_size, 'Unknown')                    AS warehouse_size,
  COALESCE(wd.node_count, 3)                                AS node_count,
  wc.total_dbus,
  ROUND(wc.dbu_cost_usd, 2)                                 AS dbu_cost_usd,
  wc.billed_hours,
  COALESCE(qa.active_query_hours, 0)                        AS active_query_hours,
  GREATEST(wc.billed_hours - COALESCE(qa.active_query_hours, 0), 0)
                                                            AS estimated_idle_hours,
  -- VM cost: Classic/Pro only; Serverless = 0 (no persistent infra when idle)
  CASE WHEN COALESCE(wd.warehouse_type, 'CLASSIC') NOT LIKE '%SERVERLESS%'
       THEN ROUND(COALESCE(wd.node_count,3) * CAST(:instance_rate_per_hr AS DOUBLE) * wc.billed_hours, 2)
       ELSE 0.0
  END                                                       AS estimated_vm_cost_usd,
  CASE WHEN COALESCE(wd.warehouse_type, 'CLASSIC') NOT LIKE '%SERVERLESS%'
       THEN ROUND(COALESCE(wd.node_count,3) * CAST(:instance_rate_per_hr AS DOUBLE)
                  * GREATEST(wc.billed_hours - COALESCE(qa.active_query_hours,0), 0), 2)
       ELSE 0.0
  END                                                       AS estimated_idle_vm_cost_usd,
  ROUND(
    wc.dbu_cost_usd +
    CASE WHEN COALESCE(wd.warehouse_type,'CLASSIC') NOT LIKE '%SERVERLESS%'
         THEN COALESCE(wd.node_count,3) * CAST(:instance_rate_per_hr AS DOUBLE) * wc.billed_hours
         ELSE 0.0 END,
    2
  )                                                         AS total_estimated_cost_usd,
  CASE WHEN COALESCE(wd.warehouse_type,'') LIKE '%SERVERLESS%'
       THEN 'Serverless (no idle VM cost)'
       ELSE 'Classic/Pro (idle VM cost accrues)'
  END                                                       AS cost_model_label
FROM wh_cost wc
LEFT JOIN wh_dim       wd ON wc.warehouse_id = wd.warehouse_id
LEFT JOIN query_active qa ON wc.warehouse_id = qa.warehouse_id
ORDER BY total_estimated_cost_usd DESC
