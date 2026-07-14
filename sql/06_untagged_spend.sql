-- =============================================================================
-- 06_untagged_spend.sql
-- Untagged / unattributable spend analysis.
-- The primary tagging-hygiene adoption metric — goal is to drive to 0%.
-- Shows how cost is resolved across three tiers:
--   1. TAG              — custom_tags['tenant'] present (fully attributed)
--   2. IDENTITY_FALLBACK — identity_metadata.run_as present (partially attributed)
--   3. UNATTRIBUTABLE   — neither tag nor identity (dark spend; must be eliminated)
--
-- Inputs:
--   :time_range.min / :time_range.max — date range (inclusive, DATE)
--   :param_time_key                   — 'Day' | 'Week' | 'Month'
--
-- Output: time_key, billing_origin_product, resolution_method, cost_usd, dbus,
--         total_cost_in_period, pct_of_total
-- =============================================================================

WITH prices AS (
  SELECT sku_name, usage_unit, price_start_time,
    COALESCE(price_end_time, DATE_ADD(CURRENT_DATE, 1)) AS price_end_time,
    try_variant_get(to_variant_object(pricing), '$.effective_list.default', 'decimal(38,18)') AS unit_px
  FROM system.billing.list_prices WHERE currency_code = 'USD'
),
attribution AS (
  SELECT /*+ BROADCAST(p) */
    CAST(
      CASE
        WHEN :param_time_key = 'Week'  THEN DATE_TRUNC('WEEK',  u.usage_date)
        WHEN :param_time_key = 'Month' THEN DATE_TRUNC('MONTH', u.usage_date)
        ELSE u.usage_date
      END AS DATE
    )                                                    AS time_key,
    u.billing_origin_product,
    u.sku_name,
    CASE
      WHEN u.custom_tags['tenant'] IS NOT NULL        THEN 'TAG'
      WHEN u.identity_metadata.run_as IS NOT NULL     THEN 'IDENTITY_FALLBACK'
      ELSE 'UNATTRIBUTABLE'
    END                                                  AS resolution_method,
    SUM(u.usage_quantity * COALESCE(p.unit_px, 0))       AS cost_usd,
    SUM(u.usage_quantity)                                AS dbus
  FROM system.billing.usage u
  LEFT JOIN prices p ON u.sku_name = p.sku_name
    AND u.usage_unit = p.usage_unit
    AND u.usage_end_time BETWEEN p.price_start_time AND p.price_end_time
  WHERE u.usage_date BETWEEN :time_range.min AND :time_range.max
  GROUP BY 1, 2, 3, 4
)
SELECT
  time_key,
  billing_origin_product,
  resolution_method,
  cost_usd,
  dbus,
  SUM(cost_usd) OVER (PARTITION BY time_key)                          AS total_cost_in_period,
  ROUND(
    cost_usd / NULLIF(SUM(cost_usd) OVER (PARTITION BY time_key), 0) * 100,
    2
  )                                                                   AS pct_of_total
FROM attribution
ORDER BY time_key, resolution_method, cost_usd DESC
