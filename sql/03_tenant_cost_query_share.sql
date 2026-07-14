-- =============================================================================
-- 03_tenant_cost_query_share.sql
-- Tenant cost on SHARED warehouses via query-level compute-time share.
-- Pattern 2: allocates each warehouse-hour's cost proportionally by
-- total_task_duration_ms across all queries in that hour.
-- Weights heavy queries fairly; blended $/query also emitted.
--
-- Tenant key resolution priority:
--   1. query_tags['tenant']         — query-level tag (highest priority)
--   2. mapping table join           — UNCOMMENT the m.* lines after creating
--                                     mapping/tenant_mapping_ddl.sql
--   3. executed_by                  — fallback raw identity
--
-- Inputs:
--   :time_range.min / :time_range.max — date range (inclusive, DATE)
--   :param_time_key                   — 'Day' | 'Week' | 'Month' | 'Quarter' | 'Year'
--   :warehouse_id                     — array; ['all'] = all warehouses
--
-- Grain: (time_key, tenant_key, warehouse_id)
-- Output: time_key, tenant_key, warehouse_id, warehouse_name,
--         cost_usd, dbus, total_queries, total_compute_ms, allocation_method
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices WHERE currency_code = 'USD'
),
warehouse_hour_cost AS (
  -- Hour-level cost from billing (the amount to allocate across queries)
  SELECT
    u.usage_metadata.warehouse_id            AS warehouse_id,
    DATE_TRUNC('HOUR', u.usage_end_time)     AS usage_hour,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0)) AS hour_cost_usd,
    SUM(u.usage_quantity)                    AS hour_dbus
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name
    AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
    AND u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
  GROUP BY 1, 2
),
wh_dim AS (
  SELECT warehouse_id, warehouse_name, workspace_id
  FROM system.compute.warehouses
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) = 1
),
query_with_tenant AS (
  SELECT
    q.statement_id,
    q.compute.warehouse_id                                             AS warehouse_id,
    DATE_TRUNC('HOUR', q.start_time)                                   AS query_hour,
    -- Resolve tenant key
    COALESCE(
      q.query_tags['tenant'],        -- 1. query-level tag (highest priority)
      -- m.tenant_id,                -- 2. UNCOMMENT after mapping table setup:
      --                             --    JOIN <catalog>.<schema>.tenant_key_mapping m
      --                             --    ON q.executed_by = m.principal_name
      --                             --    AND (m.effective_to IS NULL OR m.effective_to > CURRENT_DATE)
      q.executed_by                  -- 3. fallback identity
    )                                                                  AS tenant_key,
    CASE
      WHEN q.query_tags['tenant'] IS NOT NULL THEN 'QUERY_TAG'
      -- WHEN m.tenant_id IS NOT NULL          THEN 'MAPPING'
      ELSE 'FALLBACK_IDENTITY'
    END                                                                AS resolution_method,
    COALESCE(q.total_task_duration_ms, q.execution_duration_ms, 0)    AS compute_ms,
    1                                                                  AS query_count
  FROM system.query.history q
  WHERE CAST(q.start_time AS DATE) BETWEEN :time_range.min AND :time_range.max
    AND q.compute.warehouse_id IS NOT NULL
    AND q.execution_status = 'FINISHED'
    AND (array_contains(:warehouse_id, q.compute.warehouse_id) OR array_contains(:warehouse_id, 'all'))
),
query_hour_totals AS (
  SELECT warehouse_id, query_hour, SUM(compute_ms) AS total_compute_ms_in_hour
  FROM query_with_tenant GROUP BY 1, 2
),
tenant_hour_totals AS (
  SELECT tenant_key, warehouse_id, query_hour, resolution_method,
    SUM(compute_ms)  AS tenant_compute_ms,
    SUM(query_count) AS tenant_query_count
  FROM query_with_tenant GROUP BY 1, 2, 3, 4
),
tenant_cost_hour AS (
  SELECT th.tenant_key, th.warehouse_id, th.query_hour, th.resolution_method,
    th.tenant_query_count                                                   AS queries,
    th.tenant_compute_ms,
    ht.total_compute_ms_in_hour,
    wh.hour_cost_usd * (th.tenant_compute_ms / ht.total_compute_ms_in_hour) AS allocated_cost_usd,
    wh.hour_dbus    * (th.tenant_compute_ms / ht.total_compute_ms_in_hour)  AS allocated_dbus
  FROM tenant_hour_totals th
  JOIN warehouse_hour_cost wh ON th.warehouse_id = wh.warehouse_id AND th.query_hour = wh.usage_hour
  JOIN query_hour_totals   ht ON th.warehouse_id = ht.warehouse_id AND th.query_hour = ht.query_hour
  WHERE ht.total_compute_ms_in_hour > 0
)
SELECT
  CAST(
    CASE
      WHEN :param_time_key = 'Week'    THEN DATE_TRUNC('WEEK',    tc.query_hour)
      WHEN :param_time_key = 'Month'   THEN DATE_TRUNC('MONTH',   tc.query_hour)
      WHEN :param_time_key = 'Quarter' THEN DATE_TRUNC('QUARTER', tc.query_hour)
      WHEN :param_time_key = 'Year'    THEN DATE_TRUNC('YEAR',    tc.query_hour)
      ELSE DATE(tc.query_hour)
    END AS DATE
  )                                                  AS time_key,
  tc.tenant_key,
  tc.warehouse_id,
  COALESCE(wd.warehouse_name, tc.warehouse_id)       AS warehouse_name,
  tc.resolution_method,
  SUM(tc.allocated_cost_usd)                         AS cost_usd,
  SUM(tc.allocated_dbus)                             AS dbus,
  SUM(tc.queries)                                    AS total_queries,
  SUM(tc.tenant_compute_ms)                          AS total_compute_ms,
  ROUND(SUM(tc.allocated_cost_usd) / NULLIF(SUM(tc.queries), 0), 6) AS avg_cost_per_query,
  'QUERY_SHARE'                                      AS allocation_method
FROM tenant_cost_hour tc
LEFT JOIN wh_dim wd ON tc.warehouse_id = wd.warehouse_id
GROUP BY 1, 2, 3, 4, 5
ORDER BY time_key, cost_usd DESC
