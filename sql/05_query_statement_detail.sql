-- =============================================================================
-- 05_query_statement_detail.sql
-- Query Statement Detail — the highest-value cost-per-query view.
-- Adapts the Databricks Labs dbsql/cost_per_query reference visual for
-- multi-tenant attribution. Designed as the "Cost per Query" dashboard page.
--
-- Techniques used (verbatim from Labs reference):
--   - Warehouse snapshot join (friendly names + active/deleted state)
--   - Compute-time-share cost attribution (no pre-computed table required)
--   - Multi-select array filter pattern (array_contains + 'all' escape)
--   - Discount-adjusted cost (:dbsql_discount)
--   - Dynamic top-N by user-chosen dimension (:top_n_dimension, :top_n)
--   - Dynamic group + time aggregation (:group_key, :date_agg_level)
--   - Inline HTML data-bars for $ and DBUs (HTML rendering must be enabled
--     on these columns in the dashboard table widget)
--
-- Brand colors used in data-bars (from project CSS variables):
--   $ bar:  #FF3621 (--brand red-orange)   text: #1B2733 (--text-title)
--   DBU bar: #2166CB (blue engagement)      text: #1B2733
--
-- Inputs (dashboard parameters):
--   :time_range.min / :time_range.max  — date range
--   :workspace_id                      — array; ['all'] = all workspaces
--   :warehouse_id                      — array; warehouse ID filter
--   :warehouse_name                    — array; friendly-name filter e.g.
--                                        ['My WH (id:abc123)'] or ['all']
--   :statement_id                      — array; ['all'] = all statements
--   :tenant_key                        — array; ['all'] = all tenants
--   :dbsql_discount                    — float 0–1; effective-rate discount
--                                        (0 = list price, 0.20 = 20% discount)
--   :top_n                             — int or 'all'; limit to top-N by cost
--   :top_n_dimension                   — 'Executed By'|'Tenant'|'Source Type'|
--                                        'Object Id'|'Statement Id'
--   :group_key                         — 'Warehouse Name'|'User'|'Tenant'|
--                                        'Source Type'|'Object Id'|
--                                        'Client'|'Workspace Id'
--   :date_agg_level                    — 'HOUR' | 'DAY'
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices WHERE currency_code = 'USD'
),
warehouse_hour_cost AS (
  SELECT u.usage_metadata.warehouse_id AS warehouse_id,
    DATE_TRUNC('HOUR', u.usage_end_time) AS usage_hour,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0)) AS hour_cost_usd,
    SUM(u.usage_quantity) AS hour_dbus
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
    AND u.billing_origin_product = 'SQL'
    AND u.usage_metadata.warehouse_id IS NOT NULL
  GROUP BY 1, 2
),
query_base AS (
  SELECT
    q.statement_id, q.workspace_id, q.compute.warehouse_id AS warehouse_id,
    DATE_TRUNC('HOUR', q.start_time) AS query_start_hour,
    q.start_time, q.end_time, q.executed_by, q.execution_status,
    q.client_application, q.from_result_cache,
    COALESCE(q.total_task_duration_ms, q.execution_duration_ms, 0) AS compute_ms,
    q.execution_duration_ms, q.total_duration_ms, q.total_task_duration_ms,
    COALESCE(q.waiting_at_capacity_duration_ms, 0) AS queue_ms,
    -- Derive source type and ID from nested struct (schema-validated)
    CASE
      WHEN q.query_source.job_info.job_id IS NOT NULL  THEN 'JOB'
      WHEN q.query_source.dashboard_id   IS NOT NULL   THEN 'DASHBOARD'
      WHEN q.query_source.notebook_id    IS NOT NULL   THEN 'NOTEBOOK'
      WHEN q.query_source.genie_space_id IS NOT NULL   THEN 'GENIE'
      WHEN q.query_source.alert_id       IS NOT NULL   THEN 'ALERT'
      WHEN q.query_source.sql_query_id   IS NOT NULL   THEN 'SAVED_QUERY'
      ELSE 'DIRECT'
    END AS query_source_type,
    COALESCE(
      q.query_source.job_info.job_id, q.query_source.dashboard_id,
      q.query_source.notebook_id,      q.query_source.genie_space_id,
      q.query_source.alert_id,         q.query_source.sql_query_id
    ) AS query_source_id,
    COALESCE(q.query_tags['tenant'], q.executed_by) AS tenant_key,
    CASE WHEN q.query_tags['tenant'] IS NOT NULL THEN 'QUERY_TAG' ELSE 'FALLBACK_IDENTITY' END
      AS tenant_resolution_method
  FROM system.query.history q
  WHERE CAST(q.start_time AS DATE) BETWEEN :time_range.min AND :time_range.max
    AND q.compute.warehouse_id IS NOT NULL
),
query_hour_totals AS (
  SELECT warehouse_id, query_start_hour, SUM(compute_ms) AS total_compute_ms_in_hour
  FROM query_base GROUP BY 1, 2
),
cpq_core AS (
  SELECT qb.*,
    wh.hour_cost_usd, wh.hour_dbus, ht.total_compute_ms_in_hour,
    CASE WHEN ht.total_compute_ms_in_hour > 0
         THEN wh.hour_cost_usd * (qb.compute_ms / ht.total_compute_ms_in_hour) ELSE 0
    END AS query_attributed_dollars_estimation,
    CASE WHEN ht.total_compute_ms_in_hour > 0
         THEN wh.hour_dbus * (qb.compute_ms / ht.total_compute_ms_in_hour) ELSE 0
    END AS query_attributed_dbus_estimation
  FROM query_base qb
  JOIN warehouse_hour_cost wh ON qb.warehouse_id = wh.warehouse_id AND qb.query_start_hour = wh.usage_hour
  JOIN query_hour_totals   ht ON qb.warehouse_id = ht.warehouse_id AND qb.query_start_hour = ht.query_start_hour
),
warehouse_snapshot AS (
  -- Latest warehouse record; resolves friendly names + deleted state
  SELECT warehouse_id, warehouse_name, workspace_id, change_time,
    CASE WHEN delete_time IS NOT NULL THEN 'Deleted' ELSE 'Active' END AS is_deleted
  FROM system.compute.warehouses w
  WHERE (array_contains(:workspace_id,   w.workspace_id) OR array_contains(:workspace_id, 'all'))
    AND (array_contains(:warehouse_name, CONCAT(w.warehouse_name,' (id:',w.warehouse_id,')')))
         OR array_contains(:warehouse_name, 'all'))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, warehouse_id ORDER BY change_time DESC) = 1
),
root_table AS (
  SELECT * FROM cpq_core qq
  WHERE query_attributed_dollars_estimation IS NOT NULL
    AND (array_contains(:workspace_id,  qq.workspace_id)  OR array_contains(:workspace_id,  'all'))
    AND (array_contains(:warehouse_id,  qq.warehouse_id)  OR array_contains(:warehouse_id,  'all'))
    AND (array_contains(:tenant_key,    qq.tenant_key)    OR array_contains(:tenant_key,    'all'))
    AND (array_contains(:statement_id,  qq.statement_id)  OR array_contains(:statement_id,  'all'))
    AND qq.query_start_hour BETWEEN CAST(:time_range.min AS TIMESTAMP) AND CAST(:time_range.max AS TIMESTAMP)
),
top_n_filter AS (
  -- Dynamic top-N: rank by total cost over the chosen dimension
  SELECT
    COALESCE(
      CASE WHEN :top_n_dimension = 'Executed By'  THEN executed_by      END,
      CASE WHEN :top_n_dimension = 'Tenant'       THEN tenant_key        END,
      CASE WHEN :top_n_dimension = 'Source Type'  THEN query_source_type END,
      CASE WHEN :top_n_dimension = 'Object Id'    THEN query_source_id   END,
      CASE WHEN :top_n_dimension = 'Statement Id' THEN statement_id      END,
      statement_id
    ) AS rank_key,
    ROW_NUMBER() OVER (ORDER BY SUM(query_attributed_dollars_estimation) DESC) AS cost_rank
  FROM root_table
  GROUP BY 1
),
mv_model AS (
  SELECT
    qq.*,
    CONCAT(w.warehouse_name,' (id:',w.warehouse_id,')')  AS warehouse_name_display,
    w.is_deleted                                          AS is_warehouse_deleted,
    qq.query_attributed_dollars_estimation * (1 - CAST(:dbsql_discount AS FLOAT))
                                                          AS query_attributed_dollars_with_discount,
    tn.cost_rank
  FROM root_table AS qq
  INNER JOIN warehouse_snapshot w ON qq.workspace_id = w.workspace_id AND qq.warehouse_id = w.warehouse_id
  LEFT JOIN top_n_filter AS tn ON tn.rank_key = COALESCE(
    CASE WHEN :top_n_dimension = 'Executed By'  THEN qq.executed_by      END,
    CASE WHEN :top_n_dimension = 'Tenant'       THEN qq.tenant_key        END,
    CASE WHEN :top_n_dimension = 'Source Type'  THEN qq.query_source_type END,
    CASE WHEN :top_n_dimension = 'Object Id'    THEN qq.query_source_id   END,
    CASE WHEN :top_n_dimension = 'Statement Id' THEN qq.statement_id      END,
    qq.statement_id
  )
)
SELECT
  mv.*,
  -- Dynamic group key
  CASE :group_key
    WHEN 'Warehouse Name' THEN mv.warehouse_name_display
    WHEN 'User'           THEN mv.executed_by
    WHEN 'Tenant'         THEN mv.tenant_key
    WHEN 'Source Type'    THEN mv.query_source_type
    WHEN 'Object Id'      THEN mv.query_source_id
    WHEN 'Client'         THEN mv.client_application
    WHEN 'Workspace Id'   THEN mv.workspace_id
    ELSE mv.warehouse_name_display
  END AS group_key_value,
  -- Dynamic time aggregation key
  CASE WHEN :date_agg_level = 'HOUR'
       THEN DATE_TRUNC('HOUR', mv.start_time)::TIMESTAMP::STRING
       ELSE DATE_TRUNC('DAY',  mv.start_time)::DATE::STRING
  END AS time_agg_key,
  -- Inline HTML data-bar: allocated $ (brand color #FF3621, text #1B2733)
  --   HTML rendering MUST be enabled on this column in the table widget
  MAX(mv.query_attributed_dollars_with_discount) OVER() AS fully_loaded_max_usd,
  MIN(mv.query_attributed_dollars_with_discount) OVER() AS fully_loaded_min_usd,
  COALESCE(CONCAT(
    '<div style="position:relative;height:20px;border-radius:4px;overflow:hidden;">',
    '<div style="position:absolute;width:',
    ROUND(
      (mv.query_attributed_dollars_with_discount - MIN(mv.query_attributed_dollars_with_discount) OVER())
      / NULLIF(MAX(mv.query_attributed_dollars_with_discount) OVER() - MIN(mv.query_attributed_dollars_with_discount) OVER(), 0)
      * 100, 2),
    '%;height:100%;background:#FF3621;border-radius:4px;"></div>',
    '<span style="position:absolute;width:100%;text-align:center;line-height:20px;font-weight:bold;color:#1B2733;">,
    FORMAT_NUMBER(mv.query_attributed_dollars_with_discount, 2), '</span></div>'),
  '--') AS allocated_dollars_bar_html,
  -- Inline HTML data-bar: allocated DBUs (blue #2166CB, text #1B2733)
  MAX(mv.query_attributed_dbus_estimation) OVER() AS fully_loaded_max_dbus,
  MIN(mv.query_attributed_dbus_estimation) OVER() AS fully_loaded_min_dbus,
  COALESCE(CONCAT(
    '<div style="position:relative;height:20px;border-radius:4px;overflow:hidden;">',
    '<div style="position:absolute;width:',
    ROUND(
      (mv.query_attributed_dbus_estimation - MIN(mv.query_attributed_dbus_estimation) OVER())
      / NULLIF(MAX(mv.query_attributed_dbus_estimation) OVER() - MIN(mv.query_attributed_dbus_estimation) OVER(), 0)
      * 100, 2),
    '%;height:100%;background:#2166CB;border-radius:4px;"></div>',
    '<span style="position:absolute;width:100%;text-align:center;line-height:20px;font-weight:bold;color:#1B2733;">',
    FORMAT_NUMBER(mv.query_attributed_dbus_estimation, 2), '</span></div>'),
  '--') AS allocated_dbus_bar_html
FROM mv_model AS mv
WHERE (LOWER(CAST(:top_n AS STRING)) = 'all' OR mv.cost_rank <= TRY_CAST(:top_n AS INT))
ORDER BY mv.cost_rank, mv.query_attributed_dollars_with_discount DESC
