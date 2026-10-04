-- =====================================================================
-- Sakura-Con 2026 — Analysis Queries
--
-- Doubles as interview practice: each query uses a pattern that shows up
-- constantly in StrataScratch mediums (window functions, running totals,
-- rank-within-group, basket analysis, self-joins).
--
-- Every revenue query filters on d.is_trading_day. The account contains a
-- pre-convention terminal test — a token charge on a date with no other
-- activity — and counting it would put a phantom day beside a real convention.
-- The filter names the concept rather than a date, so it keeps working when
-- the next event's data arrives.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Revenue by category, with share of total
--    Pattern: aggregate + window function over the aggregate.
-- ---------------------------------------------------------------------
SELECT c.category_name,
       SUM(f.quantity)                                              AS units_sold,
       SUM(f.net_sales)                                        AS revenue,
       ROUND(100.0 * SUM(f.net_sales)
             / SUM(SUM(f.net_sales)) OVER (), 1)               AS pct_of_total
FROM warehouse.fact_sales_line f
JOIN warehouse.dim_item     i ON i.item_key = f.item_key
JOIN warehouse.dim_category c ON c.category_key = i.category_key
JOIN warehouse.dim_date     d ON d.date_key = f.date_key
WHERE d.is_trading_day
GROUP BY c.category_name
ORDER BY revenue DESC;


-- ---------------------------------------------------------------------
-- 2. Top 3 items within each category
--    Pattern: RANK inside a CTE, filtered outside. The single most common
--    "top N per group" interview question.
-- ---------------------------------------------------------------------
WITH item_revenue AS (
    SELECT c.category_name,
           i.item_name,
           SUM(f.net_sales) AS revenue,
           RANK() OVER (PARTITION BY c.category_name
                        ORDER BY SUM(f.net_sales) DESC) AS rnk
    FROM warehouse.fact_sales_line f
    JOIN warehouse.dim_item     i ON i.item_key = f.item_key
    JOIN warehouse.dim_category c ON c.category_key = i.category_key
    JOIN warehouse.dim_date     d ON d.date_key = f.date_key
    WHERE d.is_trading_day
    GROUP BY c.category_name, i.item_name
)
SELECT category_name, item_name, revenue, rnk
FROM item_revenue
WHERE rnk <= 3
ORDER BY category_name, rnk;


-- ---------------------------------------------------------------------
-- 3. Cumulative revenue within each event
--    Pattern: running total with SUM() OVER (PARTITION BY ... ORDER BY ...).
--
--    The PARTITION BY is the whole point. Without it the running total carries
--    across event boundaries, so a one-off sale in March inflates the opening
--    figure for a convention a month later.
-- ---------------------------------------------------------------------
SELECT d.event_name,
       d.convention_day,
       d.full_date,
       SUM(f.net_sales)                                    AS daily_revenue,
       -- The explicit frame is required, not stylistic: Redshift rejects an
       -- aggregate window function that has ORDER BY without one. Postgres
       -- defaults to exactly this frame, which is why it only fails in
       -- production.
       SUM(SUM(f.net_sales)) OVER (PARTITION BY d.event_name
                                   ORDER BY d.full_date
                                   ROWS BETWEEN UNBOUNDED PRECEDING
                                            AND CURRENT ROW)   AS cumulative_revenue
FROM warehouse.fact_sales_line f
JOIN warehouse.dim_date d ON d.date_key = f.date_key
WHERE d.is_trading_day
GROUP BY d.event_name, d.convention_day, d.full_date
ORDER BY d.full_date;


-- ---------------------------------------------------------------------
-- 4. Basket analysis — value and size per transaction
--    Pattern: aggregating a fact table to a coarser grain than it is
--    stored at, using the degenerate transaction_id dimension.
-- ---------------------------------------------------------------------
WITH baskets AS (
    SELECT f.transaction_id,
           d.event_name,
           d.convention_day,
           d.full_date,
           COUNT(*)          AS lines_in_basket,
           SUM(f.quantity)   AS units,
           SUM(f.net_sales)  AS basket_value
    FROM warehouse.fact_sales_line f
    JOIN warehouse.dim_date d ON d.date_key = f.date_key
    WHERE d.is_trading_day
    GROUP BY f.transaction_id, d.event_name, d.convention_day, d.full_date
)
SELECT event_name,
       convention_day,
       COUNT(*)                        AS transactions,
       ROUND(AVG(basket_value), 2)     AS avg_basket_value,
       ROUND(AVG(units), 2)            AS avg_units_per_basket,
       MAX(basket_value)               AS largest_basket
FROM baskets
GROUP BY event_name, convention_day
ORDER BY event_name, convention_day;


-- ---------------------------------------------------------------------
-- 5. Hourly sales curve
--    Pattern: bucketing a time column, then finding the peak per day.
--    Directly actionable — tells you when to staff the booth.
-- ---------------------------------------------------------------------
SELECT d.event_name,
       d.convention_day,
       EXTRACT(HOUR FROM f.sale_time)::int  AS hour_of_day,
       COUNT(DISTINCT f.transaction_id)     AS transactions,
       SUM(f.net_sales)                     AS revenue
FROM warehouse.fact_sales_line f
JOIN warehouse.dim_date d ON d.date_key = f.date_key
WHERE f.sale_time IS NOT NULL
  AND d.is_trading_day
GROUP BY d.event_name, d.convention_day, hour_of_day
ORDER BY d.event_name, d.convention_day, hour_of_day;


-- ---------------------------------------------------------------------
-- 6. Items frequently bought together
--    Pattern: self-join on the fact table at basket grain. This is the
--    query that produces an actual business recommendation — which items
--    to bundle at next year's booth.
--
--    No is_trading_day filter here, deliberately: this counts co-occurrence
--    rather than revenue, and a single-line transaction cannot produce a pair.
--    The join would cost a scan and change nothing.
-- ---------------------------------------------------------------------
SELECT a.item_name AS item_a,
       b.item_name AS item_b,
       COUNT(*)    AS times_bought_together
FROM warehouse.fact_sales_line fa
JOIN warehouse.fact_sales_line fb
  ON fa.transaction_id = fb.transaction_id
 AND fa.item_key < fb.item_key          -- avoids self-pairs and mirrored duplicates
JOIN warehouse.dim_item a ON a.item_key = fa.item_key
JOIN warehouse.dim_item b ON b.item_key = fb.item_key
GROUP BY a.item_name, b.item_name
HAVING COUNT(*) > 1
ORDER BY times_bought_together DESC
LIMIT 15;


-- ---------------------------------------------------------------------
-- 7. Day-over-day velocity — what's accelerating, not just what's biggest
--    Pattern: LAG() for period-over-period comparison. Complements query 1
--    (cumulative revenue) rather than replacing it: an item can be climbing
--    fast while still trailing the overall leader in total revenue.
--
--    CAVEAT: booth hours differ by day (Day 1 ran ~12:00-18:00; Days 2-3
--    opened earlier, ~10:00-15:00), so a raw day-over-day increase partly
--    reflects more hours open, not pure demand growth. Read this as directional,
--    not a clean normalized rate. Also only 2 day-over-day transitions exist
--    (Day1->Day2, Day2->Day3) -- thin evidence for any single item.
--
--    The stronger version of this question is convention-over-convention
--    velocity. dim_date already carries the event identifier that needs, so
--    the query works unchanged as soon as a second event's data arrives
--    through the scheduled pipeline.
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT i.item_name,
           i.category_name,
           d.event_name,
           d.full_date,
           d.convention_day,
           SUM(f.quantity)  AS units,
           SUM(f.net_sales) AS revenue
    FROM warehouse.fact_sales_line f
    JOIN warehouse.dim_item i ON i.item_key = f.item_key
    JOIN warehouse.dim_date d ON d.date_key = f.date_key
    WHERE d.is_trading_day
    GROUP BY i.item_name, i.category_name, d.event_name, d.full_date, d.convention_day
),
with_change AS (
    -- PARTITION BY item AND event: comparing an item's April sales against its
    -- March sales is not day-over-day velocity, it is two unrelated numbers
    -- subtracted from each other.
    SELECT *,
           LAG(units) OVER (PARTITION BY item_name, event_name
                            ORDER BY full_date) AS prev_day_units,
           units - LAG(units) OVER (PARTITION BY item_name, event_name
                                    ORDER BY full_date) AS unit_change
    FROM daily
)
SELECT item_name,
       category_name,
       event_name,
       convention_day,
       prev_day_units,
       units AS today_units,
       unit_change,
       CASE WHEN prev_day_units > 0
            THEN ROUND(100.0 * unit_change / prev_day_units, 0)
       END AS pct_change
FROM with_change
WHERE prev_day_units IS NOT NULL   -- Day 1 has no prior day to compare against
ORDER BY unit_change DESC NULLS LAST
LIMIT 15;
