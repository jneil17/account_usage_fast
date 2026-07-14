-- =============================================================================
-- 02_tenant_cost_by_tag.sql
-- Tenant cost using custom_tags['tenant'] as the primary attribution key.
-- Pattern 1 (tag-based) — simplest and most reliable when all compute carries tags.
-- Untagged usage appears as tenant = 'Untagged'; drive this to $0 / 0%.
--
-- Inputs:
--   :time_range.min / :time_range.max — date range (inclusive, DATE)
--   :param_time_key                   — 'Day' | 'Week' | 'Month' | 'Quarter' | 'Year'
--   :top_n_tenants                    — integer; tenants ranked below this roll into 'Other'
--
-- Grain: (time_key, tenant, is_tagged)
-- Output: time_key, tenant, is_tagged (1/0), cost_usd, dbus, tag_resolution_method
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices
  WHERE currency_code = 'USD'
),
base AS (
  SELECT /*+ BROADCAST(p) */
    CAST(
      CASE
        WHEN :param_time_key = 'Week'    THEN DATE_TRUNC('WEEK',    u.usage_date)
        WHEN :param_time_key = 'Month'   THEN DATE_TRUNC('MONTH',   u.usage_date)
        WHEN :param_time_key = 'Quarter' THEN DATE_TRUNC('QUARTER', u.usage_date)
        WHEN :param_time_key = 'Year'    THEN DATE_TRUNC('YEAR',    u.usage_date)
        ELSE u.usage_date
      END AS DATE
    )                                                      AS time_key,
    COALESCE(u.custom_tags['tenant'], 'Untagged')          AS tenant,
    CASE WHEN u.custom_tags['tenant'] IS NOT NULL THEN 1 ELSE 0 END AS is_tagged,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0))         AS cost_usd,
    SUM(u.usage_quantity)                                  AS dbus
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name
    AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
  GROUP BY 1, 2, 3
),
tenant_rank AS (
  SELECT tenant, ROW_NUMBER() OVER (ORDER BY SUM(cost_usd) DESC) AS rn
  FROM base
  GROUP BY tenant
)
SELECT
  b.time_key,
  CASE WHEN tr.rn <= :top_n_tenants THEN b.tenant ELSE 'Other (not top-N)' END AS tenant,
  b.is_tagged,
  SUM(b.cost_usd) AS cost_usd,
  SUM(b.dbus)     AS dbus,
  'TAG'           AS tag_resolution_method
FROM base b
LEFT JOIN tenant_rank tr ON b.tenant = tr.tenant
GROUP BY 1, 2, 3
ORDER BY time_key, cost_usd DESC
