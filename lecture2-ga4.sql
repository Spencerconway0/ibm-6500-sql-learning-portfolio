-- Lecture 2: Intermediate/Advanced BigQuery for GA4
-- Spencer Conway | IBM 6500
-- GoogleSQL. Highlight and run one numbered statement at a time in BigQuery.

-- 01. CTE: total users and new users in November.
WITH UserInfo AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name IN ('first_visit', 'first_open'), 1, 0)) AS is_new_user
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
    AND user_pseudo_id IS NOT NULL
  GROUP BY user_pseudo_id
)
SELECT
  COUNT(*) AS total_users,
  COALESCE(SUM(is_new_user), 0) AS new_users
FROM UserInfo;

-- 02. Scalar subquery: one page URL per page_view event.
SELECT
  TIMESTAMP_MICROS(event_timestamp) AS event_time,
  (
    SELECT value.string_value
    FROM UNNEST(event_params)
    WHERE key = 'page_location'
    LIMIT 1
  ) AS page_location
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'page_view'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201202'
LIMIT 50;

-- 03. Flatten items: count purchase item rows by day and item name.
SELECT
  e.event_date,
  item.item_name,
  COUNT(*) AS item_rows
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
CROSS JOIN UNNEST(e.items) AS item
WHERE e.event_name = 'purchase'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY e.event_date, item.item_name
ORDER BY item_rows DESC, e.event_date, item.item_name
LIMIT 20;

-- 04. STRING_AGG: make one alphabetized list of event types per day.
SELECT
  event_date,
  STRING_AGG(DISTINCT event_name, ', ' ORDER BY event_name) AS events_seen
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201203'
GROUP BY event_date
ORDER BY event_date;

-- 05. ARRAY_AGG: collect cart item names per user across December.
SELECT
  e.user_pseudo_id,
  ARRAY_AGG(item.item_name IGNORE NULLS ORDER BY e.event_timestamp, item.item_name)
    AS items_added_to_cart
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
CROSS JOIN UNNEST(e.items) AS item
WHERE e.event_name = 'add_to_cart'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  AND e.user_pseudo_id IS NOT NULL
GROUP BY e.user_pseudo_id
ORDER BY e.user_pseudo_id
LIMIT 10;

-- 06. ARRAY_AGG with STRUCT: summarize cart item rows by user and session.
WITH add_to_cart AS (
  SELECT
    e.user_pseudo_id,
    (
      SELECT value.int_value
      FROM UNNEST(e.event_params)
      WHERE key = 'ga_session_id'
      LIMIT 1
    ) AS session_id,
    TIMESTAMP_MICROS(e.event_timestamp) AS event_time,
    item.item_id,
    item.item_name,
    item.quantity,
    item.price
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
  CROSS JOIN UNNEST(e.items) AS item
  WHERE e.event_name = 'add_to_cart'
    AND _TABLE_SUFFIX BETWEEN '20210101' AND '20210131'
    AND e.user_pseudo_id IS NOT NULL
)
SELECT
  user_pseudo_id,
  session_id,
  COUNT(*) AS total_cart_item_rows,
  ARRAY_AGG(
    STRUCT(item_id, item_name, quantity, price, event_time)
    ORDER BY quantity DESC, event_time, item_id, item_name, price
    LIMIT 10
  ) AS cart_items
FROM add_to_cart
WHERE session_id IS NOT NULL
GROUP BY user_pseudo_id, session_id
ORDER BY user_pseudo_id, session_id;

-- 07. LEFT JOIN: show daily users and distinct purchase transactions.
WITH daily_users AS (
  SELECT
    event_date,
    COUNT(DISTINCT user_pseudo_id) AS users
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
),
daily_purchases AS (
  SELECT
    event_date,
    COUNT(DISTINCT NULLIF(ecommerce.transaction_id, '')) AS purchases
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
)
SELECT
  u.event_date,
  u.users,
  COALESCE(p.purchases, 0) AS purchases,
  ROUND(SAFE_DIVIDE(COALESCE(p.purchases, 0), u.users) * 100, 2)
    AS transactions_per_100_users
FROM daily_users AS u
LEFT JOIN daily_purchases AS p
  ON u.event_date = p.event_date
ORDER BY u.event_date;

-- 08. RANK and QUALIFY: keep the top three event ranks per day.
WITH daily_event_counts AS (
  SELECT
    event_date,
    event_name,
    COUNT(*) AS events
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
  GROUP BY event_date, event_name
)
SELECT
  event_date,
  event_name,
  events,
  RANK() OVER (PARTITION BY event_date ORDER BY events DESC) AS rnk
FROM daily_event_counts
QUALIFY rnk <= 3
ORDER BY event_date, rnk, event_name;

-- 09. Window average: count purchase events on a complete December calendar.
WITH calendar AS (
  SELECT dt
  FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2020-12-01', DATE '2020-12-31')) AS dt
),
daily_purchases AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS dt,
    COUNT(*) AS purchase_events
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY dt
)
SELECT
  calendar.dt,
  COALESCE(daily_purchases.purchase_events, 0) AS purchase_events,
  AVG(COALESCE(daily_purchases.purchase_events, 0)) OVER (
    ORDER BY calendar.dt
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS purchases_7d_avg
FROM calendar
LEFT JOIN daily_purchases USING (dt)
ORDER BY calendar.dt;

-- 10. APPROX_COUNT_DISTINCT: estimate unique users for each event type.
SELECT
  event_name,
  APPROX_COUNT_DISTINCT(user_pseudo_id) AS approx_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY event_name
ORDER BY approx_users DESC, event_name
LIMIT 15;
