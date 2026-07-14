-- =============================================================================
-- 04_cost_per_query_core.sql
-- Core per-query cost output. One row per statement_id.
-- Extends the Databricks Labs dbsql/cost_per_query approach with multi-tenant
-- attribution. This is the base dataset for the Cost per Query dashboard page.
--
-- Attribution method: compute-time-share
--   query_attributed_cost = (query_compute_ms / warehouse_hour_compute_ms) * warehouse_hour_cost
--
-- NOTE: For production, consider materializing this as a scheduled table:
--   CREATE OR REPLACE TABLE <catalog>.<schema>.cpq_core AS <this query>
--   Then downstream queries can reference cpq_core instead of recomputing.
--
-- Inputs:
--   :time_range.min / :time_range.max — date range (inclusive, DATE)
--   :warehouse_id                     — array; ['all'] = all warehouses
--
-- Grain: one row per statement_id
-- Key output columns:
--   statement_id, workspace_id, warehouse_id, query_start_hour,
--   start_time, end_time, executed_by, execution_status, client_application,
--   from_result_cache, query_source_type, query_source_id,
--   tenant_key, tenant_resolution_method,
--   compute_ms, execution_duration_ms, total_task_duration_ms, queue_ms,
--   read_rows, produced_rows, read_bytes, written_bytes, spilled_local_bytes,
--   hour_cost_usd, hour_dbus, total_compute_ms_in_hour,
--   query_attributed_dollars_estimation, query_attributed_dbus_estimation
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices WHERE currency_code = 'USD'
),
warehouse_hour_cost AS (
  SELECT
    u.usage_metadata.warehouse_id        AS warehouse_id,
    DATE_TRUNC('HOUR', u.usage_end_time) AS usage_hour,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0)) AS hour_cost_usd,
    SUM(u.usage_quantity)                AS hour_dbus
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name
    AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
    AND u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
  GROUP BY 1, 2
),
query_base AS (
  SELECT
    q.statement_id,
    q.workspace_id,
    q.compute.warehouse_id                                          AS warehouse_id,
    DATE_TRUNC('HOUR', q.start_time)                                AS query_start_hour,
    q.start_time,
    q.end_time,
    q.executed_by,
    q.execution_status,
    q.client_application,
    q.from_result_cache,
    -- Derive source type from query_source nested struct
    CASE
      WHEN q.query_source.job_info.job_id     IS NOT NULL THEN 'JOB'
      WHEN q.query_source.dashboard_id        IS NOT NULL THEN 'DASHBOARD'
      WHEN q.query_source.notebook_id         IS NOT NULL THEN 'NOTEBOOK'
      WHEN q.query_source.genie_space_id      IS NOT NULL THEN 'GENIE'
      WHEN q.query_source.alert_id            IS NOT NULL THEN 'ALERT'
      WHEN q.query_source.sql_query_id        IS NOT NULL THEN 'SAVED_QUERY'
      ELSE 'DIRECT'
    END                                                             AS query_source_type,
    COALESCE(
      q.query_source.job_info.job_id,
      q.query_source.dashboard_id,
      q.query_source.notebook_id,
      q.query_source.genie_space_id,
      q.query_source.alert_id,
      q.query_source.sql_query_id
    )                                                               AS query_source_id,
    -- Tenant key resolution: query tag → mapping table → executed_by
    COALESCE(
      q.query_tags['tenant'],     -- highest priority: query-level tag
      -- m.tenant_id,             -- UNCOMMENT after mapping table setup
      q.executed_by               -- fallback identity
    )                                                               AS tenant_key,
    CASE
      WHEN q.query_tags['tenant'] IS NOT NULL THEN 'QUERY_TAG'
      -- WHEN m.tenant_id IS NOT NULL          THEN 'MAPPING'
      ELSE 'FALLBACK_IDENTITY'
    END                                                             AS tenant_resolution_method,
    COALESCE(q.total_task_duration_ms, q.execution_duration_ms, 0) AS compute_ms,
    q.execution_duration_ms,
    q.total_duration_ms,
    q.total_task_duration_ms,
    COALESCE(q.waiting_at_capacity_duration_ms, 0)                 AS queue_ms,
    q.read_rows,
    q.produced_rows,
    q.read_bytes,
    q.written_bytes,
    q.spilled_local_bytes
  FROM system.query.history q
  WHERE CAST(q.start_time AS DATE) BETWEEN :time_range.min AND :time_range.max
    AND q.compute.warehouse_id IS NOT NULL
    AND (array_contains(:warehouse_id, q.compute.warehouse_id) OR array_contains(:warehouse_id, 'all'))
),
query_hour_totals AS (
  SELECT warehouse_id, query_start_hour,
    SUM(compute_ms) AS total_compute_ms_in_hour
  FROM query_base GROUP BY 1, 2
)
SELECT
  qb.*,
  wh.hour_cost_usd,
  wh.hour_dbus,
  ht.total_compute_ms_in_hour,
  -- Proportional cost allocation (compute-time share)
  CASE WHEN ht.total_compute_ms_in_hour > 0
       THEN wh.hour_cost_usd * (qb.compute_ms / ht.total_compute_ms_in_hour)
       ELSE 0 END AS query_attributed_dollars_estimation,
  CASE WHEN ht.total_compute_ms_in_hour > 0
       THEN wh.hour_dbus * (qb.compute_ms / ht.total_compute_ms_in_hour)
       ELSE 0 END AS query_attributed_dbus_estimation
FROM query_base qb
JOIN warehouse_hour_cost wh ON qb.warehouse_id = wh.warehouse_id
                            AND qb.query_start_hour = wh.usage_hour
JOIN query_hour_totals   ht ON qb.warehouse_id = ht.warehouse_id
                            AND qb.query_start_hour = ht.query_start_hour
ORDER BY query_attributed_dollars_estimation DESC
