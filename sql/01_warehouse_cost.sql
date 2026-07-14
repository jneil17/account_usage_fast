-- =============================================================================
-- 01_warehouse_cost.sql
-- Warehouse SQL cost by SKU, warehouse type, and time period.
-- Source of truth: system.billing.usage × system.billing.list_prices
--
-- Inputs (dashboard parameters / query variables):
--   :time_range.min / :time_range.max  — date range (inclusive, DATE)
--   :param_time_key                    — 'Day' | 'Week' | 'Month' | 'Quarter' | 'Year'
--   :warehouse_id                      — array; pass ['all'] to include all warehouses
--   :workspace_id                      — array; pass ['all'] to include all workspaces
--
-- Grain: (time_key, warehouse_id, warehouse_type, warehouse_size, workspace_id, sku_name)
-- Output: time_key, warehouse_id, warehouse_name, warehouse_type, warehouse_size,
--         wh_status, workspace_id, sku_name, cost_usd, dbus
-- =============================================================================

WITH prices AS (
  -- Always join to list_prices; never hard-code $/DBU
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices
  WHERE currency_code = 'USD'
),
wh_dim AS (
  -- Latest warehouse state (handles renames + deleted warehouses)
  SELECT warehouse_id, warehouse_name, warehouse_type, warehouse_size,
    CASE WHEN delete_time IS NOT NULL THEN 'Deleted' ELSE 'Active' END AS wh_status
  FROM system.compute.warehouses
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) = 1
)
SELECT
  CAST(
    CASE
      WHEN :param_time_key = 'Week'    THEN DATE_TRUNC('WEEK',    u.usage_date)
      WHEN :param_time_key = 'Month'   THEN DATE_TRUNC('MONTH',   u.usage_date)
      WHEN :param_time_key = 'Quarter' THEN DATE_TRUNC('QUARTER', u.usage_date)
      WHEN :param_time_key = 'Year'    THEN DATE_TRUNC('YEAR',    u.usage_date)
      ELSE u.usage_date
    END AS DATE
  )                                                    AS time_key,
  u.usage_metadata.warehouse_id                        AS warehouse_id,
  COALESCE(wd.warehouse_name, u.usage_metadata.warehouse_id) AS warehouse_name,
  COALESCE(wd.warehouse_type, 'Unknown')               AS warehouse_type,   -- PRO | CLASSIC | PRO_SERVERLESS
  COALESCE(wd.warehouse_size, 'Unknown')               AS warehouse_size,
  COALESCE(wd.wh_status, 'Unknown')                    AS wh_status,
  u.workspace_id,
  u.sku_name,
  SUM(u.usage_quantity * COALESCE(p.unit_px, 0))       AS cost_usd,
  SUM(u.usage_quantity)                                AS dbus
FROM system.billing.usage u
LEFT JOIN prices  p  ON u.sku_name = p.sku_name
                     AND u.usage_unit = p.usage_unit
                     AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
LEFT JOIN wh_dim  wd ON u.usage_metadata.warehouse_id = wd.warehouse_id
WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
  AND u.billing_origin_product = 'SQL'
  AND u.usage_metadata.warehouse_id IS NOT NULL
  AND (array_contains(:workspace_id,  u.workspace_id)                    OR array_contains(:workspace_id,  'all'))
  AND (array_contains(:warehouse_id,  u.usage_metadata.warehouse_id)     OR array_contains(:warehouse_id,  'all'))
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
ORDER BY time_key, cost_usd DESC
