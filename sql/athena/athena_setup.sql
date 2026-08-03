-- =========================================================================
-- NYC yellow-taxi lakehouse on Athena
--
-- Account : 351205763668
-- Region  : us-east-2  (Athena and Glue are regional -- must match the bucket)
-- Bucket  : s3://nyc-taxi-bucket-351205763668
-- Data    : 65 monthly parquet files, 2021-01 .. 2026-05, 217,762,236 trips
--           (new months arrive via the taxi-ingest Lambda, monthly schedule)
--
-- S3 layout:
--   raw/yellow/year=YYYY/month=MM/yellow_tripdata_YYYY-MM.parquet
--   raw/zones/taxi_zone_lookup.csv
--   curated/<table>/                 <- CTAS output
--   athena-results/                  <- query output, lifecycle-expired at 7d
--
-- Run one statement at a time (Athena executes a single statement per call).
-- =========================================================================

CREATE DATABASE IF NOT EXISTS nyc_taxi;


-- =========================================================================
-- SECTION 1 -- Raw tables over S3
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1a. Narrow table over all 60 files.
--
-- Declares only columns whose parquet type is stable across all five years,
-- which makes it the cheapest table to query. Use this unless you need
-- ratecodeid or passenger_count (see 1c for why those are special).
--
-- Partition projection computes partitions from the rules below instead of
-- storing them in the Glue catalog: no crawler ($0.15/run), no MSCK REPAIR,
-- and partitions can never go stale. Requires a perfectly regular layout,
-- which this is.
--
-- projection.month.digits = '2' is load-bearing. Without it Athena generates
-- month=3 rather than month=03, matches nothing, and every query silently
-- returns zero rows with no error.
-- -------------------------------------------------------------------------

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.yellow_raw (
    tpep_pickup_datetime  TIMESTAMP,
    tpep_dropoff_datetime TIMESTAMP,
    trip_distance         DOUBLE,
    pulocationid          BIGINT,
    dolocationid          BIGINT,
    payment_type          BIGINT,
    fare_amount           DOUBLE,
    tip_amount            DOUBLE,
    total_amount          DOUBLE
)
PARTITIONED BY (year INT, month INT)
STORED AS PARQUET
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/yellow/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    -- Widen this when a new calendar year starts arriving, or its files sit
    -- in S3 invisible to Athena -- no error, just silently absent.
    'projection.year.range'     = '2021,2026',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '1,12',
    'projection.month.digits'   = '2',
    'storage.location.template' = 's3://nyc-taxi-bucket-351205763668/raw/yellow/year=${year}/month=${month}/'
);


-- -------------------------------------------------------------------------
-- 1b. Zone lookup (CSV).
--
-- OpenCSVSerde reads every column as STRING -- it has no type inference --
-- so casting happens downstream in dim_location. skip.header.line.count
-- drops the header row.
-- -------------------------------------------------------------------------

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.zones_raw (
    locationid   STRING,
    borough      STRING,
    zone         STRING,
    service_zone STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"')
STORED AS TEXTFILE
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/zones/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- -------------------------------------------------------------------------
-- 1c. Era-scoped tables -- schema drift workaround.
--
-- TLC changed the parquet types of ratecodeid and passenger_count from
-- DOUBLE to INT64 starting with the 2023-02 file. Athena will NOT coerce
-- between int and double; a mismatched read fails outright with:
--     HIVE_BAD_DATA: Malformed Parquet file. Field ratecodeid's type INT64
--     ... is incompatible with type double defined in table schema
--
-- (Integer WIDENING is fine, which is why pulocationid is declared BIGINT
-- and reads both the int64 files and the int32 ones without complaint.)
--
-- Verified by reading the footer of all 60 files: exactly two signatures,
-- switching at 2023-02. 2023 therefore straddles the boundary and needs two
-- tables, because projection ranges are a rectangular year x month product
-- and cannot express "up to January of a given year".
--
--   yellow_2021_2022   2021-01 .. 2022-12   DOUBLE
--   yellow_2023_jan    2023-01              DOUBLE
--   yellow_2023_rest   2023-02 .. 2023-12   BIGINT
--   yellow_2024_onward 2024-01 .. 2026-12   BIGINT
--
-- The 2026 files were checked footer-by-footer on arrival and match 2025
-- exactly, so they extend the existing era rather than opening a new one.
-- ALWAYS re-check when a new year lands: sampling one month per year would
-- have missed the 2023-02 switch entirely.
--
-- fact_trips (section 3) unions all four and casts to a single type, so
-- nothing downstream has to know this happened.
-- -------------------------------------------------------------------------

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.yellow_2021_2022 (
    tpep_pickup_datetime  TIMESTAMP,
    tpep_dropoff_datetime TIMESTAMP,
    trip_distance         DOUBLE,
    pulocationid          BIGINT,
    dolocationid          BIGINT,
    payment_type          BIGINT,
    ratecodeid            DOUBLE,
    passenger_count       DOUBLE,
    fare_amount           DOUBLE,
    tip_amount            DOUBLE,
    total_amount          DOUBLE
)
PARTITIONED BY (year INT, month INT)
STORED AS PARQUET
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/yellow/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    'projection.year.range'     = '2021,2022',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '1,12',
    'projection.month.digits'   = '2',
    'storage.location.template' = 's3://nyc-taxi-bucket-351205763668/raw/yellow/year=${year}/month=${month}/'
);

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.yellow_2023_jan (
    tpep_pickup_datetime  TIMESTAMP,
    tpep_dropoff_datetime TIMESTAMP,
    trip_distance         DOUBLE,
    pulocationid          BIGINT,
    dolocationid          BIGINT,
    payment_type          BIGINT,
    ratecodeid            DOUBLE,
    passenger_count       DOUBLE,
    fare_amount           DOUBLE,
    tip_amount            DOUBLE,
    total_amount          DOUBLE
)
PARTITIONED BY (year INT, month INT)
STORED AS PARQUET
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/yellow/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    'projection.year.range'     = '2023,2023',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '1,1',
    'projection.month.digits'   = '2',
    'storage.location.template' = 's3://nyc-taxi-bucket-351205763668/raw/yellow/year=${year}/month=${month}/'
);

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.yellow_2023_rest (
    tpep_pickup_datetime  TIMESTAMP,
    tpep_dropoff_datetime TIMESTAMP,
    trip_distance         DOUBLE,
    pulocationid          BIGINT,
    dolocationid          BIGINT,
    payment_type          BIGINT,
    ratecodeid            BIGINT,
    passenger_count       BIGINT,
    fare_amount           DOUBLE,
    tip_amount            DOUBLE,
    total_amount          DOUBLE
)
PARTITIONED BY (year INT, month INT)
STORED AS PARQUET
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/yellow/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    'projection.year.range'     = '2023,2023',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '2,12',
    'projection.month.digits'   = '2',
    'storage.location.template' = 's3://nyc-taxi-bucket-351205763668/raw/yellow/year=${year}/month=${month}/'
);

CREATE EXTERNAL TABLE IF NOT EXISTS nyc_taxi.yellow_2024_onward (
    tpep_pickup_datetime  TIMESTAMP,
    tpep_dropoff_datetime TIMESTAMP,
    trip_distance         DOUBLE,
    pulocationid          BIGINT,
    dolocationid          BIGINT,
    payment_type          BIGINT,
    ratecodeid            BIGINT,
    passenger_count       BIGINT,
    fare_amount           DOUBLE,
    tip_amount            DOUBLE,
    total_amount          DOUBLE
)
PARTITIONED BY (year INT, month INT)
STORED AS PARQUET
LOCATION 's3://nyc-taxi-bucket-351205763668/raw/yellow/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    'projection.year.range'     = '2024,2026',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '1,12',
    'projection.month.digits'   = '2',
    'storage.location.template' = 's3://nyc-taxi-bucket-351205763668/raw/yellow/year=${year}/month=${month}/'
);


-- =========================================================================
-- SECTION 2 -- Dimensions (CTAS -> parquet under curated/)
--
-- CTAS requires an EMPTY external_location. Re-running one of these after a
-- failure means clearing the prefix first:
--     aws s3 rm s3://<bucket>/curated/<table>/ --recursive
-- Athena never deletes data in your account, even for a failed CTAS.
-- =========================================================================

CREATE TABLE nyc_taxi.dim_location
WITH (format = 'PARQUET',
      external_location = 's3://nyc-taxi-bucket-351205763668/curated/dim_location/') AS
SELECT
    CAST(locationid AS BIGINT) AS location_id,
    borough,
    zone,
    service_zone
FROM nyc_taxi.zones_raw
WHERE locationid IS NOT NULL;


-- Date spine covering the loaded range. CAST(d AS DATE) is required: a
-- sequence() stepped by INTERVAL '1' DAY yields timestamp(0), which Athena's
-- parquet writer rejects ("Incorrect timestamp precision for timestamp(0)").
-- day_of_week() is 1=Monday .. 7=Sunday, so >= 6 is the weekend.

CREATE TABLE nyc_taxi.dim_date
WITH (format = 'PARQUET',
      external_location = 's3://nyc-taxi-bucket-351205763668/curated/dim_date/') AS
SELECT
    CAST(year(d) * 10000 + month(d) * 100 + day(d) AS INTEGER) AS date_key,
    CAST(d AS DATE)                                            AS full_date,
    year(d)                                                    AS "year",
    month(d)                                                   AS "month",
    day(d)                                                     AS day_of_month,
    day_of_week(d)                                             AS dow,
    day_of_week(d) >= 6                                        AS is_weekend
FROM UNNEST(sequence(DATE '2021-01-01', DATE '2026-12-31', INTERVAL '1' DAY)) AS t(d);


-- Static lookups from the TLC data dictionary.

CREATE TABLE nyc_taxi.dim_payment
WITH (format = 'PARQUET',
      external_location = 's3://nyc-taxi-bucket-351205763668/curated/dim_payment/') AS
SELECT * FROM (VALUES
    (CAST(0 AS BIGINT), 'Flex Fare trip'),
    (CAST(1 AS BIGINT), 'Credit card'),
    (CAST(2 AS BIGINT), 'Cash'),
    (CAST(3 AS BIGINT), 'No charge'),
    (CAST(4 AS BIGINT), 'Dispute'),
    (CAST(5 AS BIGINT), 'Unknown'),
    (CAST(6 AS BIGINT), 'Voided trip')
) AS t (payment_type, payment_desc);

CREATE TABLE nyc_taxi.dim_rate_code
WITH (format = 'PARQUET',
      external_location = 's3://nyc-taxi-bucket-351205763668/curated/dim_rate_code/') AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT),  'Standard rate'),
    (CAST(2 AS BIGINT),  'JFK'),
    (CAST(3 AS BIGINT),  'Newark'),
    (CAST(4 AS BIGINT),  'Nassau or Westchester'),
    (CAST(5 AS BIGINT),  'Negotiated fare'),
    (CAST(6 AS BIGINT),  'Group ride'),
    (CAST(99 AS BIGINT), 'Null/unknown')
) AS t (rate_code_id, rate_code_desc);


-- =========================================================================
-- SECTION 3 -- Fact view
--
-- A VIEW, not a CTAS table, deliberately: the source is already parquet and
-- already partitioned, so materialising it would copy ~3 GB into curated/ to
-- produce byte-equivalent data and push storage past the 5 GB free tier.
-- Views store nothing.
--
-- year and month are passed straight through, so partition pruning still
-- works through the view -- filtering fact_trips on year reads only the
-- matching files. Drop those columns and every query becomes a full scan.
-- =========================================================================

CREATE OR REPLACE VIEW nyc_taxi.fact_trips AS
SELECT
    tpep_pickup_datetime  AS pickup_time,
    tpep_dropoff_datetime AS dropoff_time,
    CAST(year(tpep_pickup_datetime) * 10000
       + month(tpep_pickup_datetime) * 100
       + day(tpep_pickup_datetime) AS INTEGER) AS pickup_date_key,
    pulocationid                    AS pickup_location_id,
    dolocationid                    AS dropoff_location_id,
    payment_type,
    CAST(ratecodeid AS BIGINT)      AS rate_code_id,
    CAST(passenger_count AS BIGINT) AS passenger_count,
    trip_distance, fare_amount, tip_amount, total_amount,
    "year", "month"
FROM nyc_taxi.yellow_2021_2022

UNION ALL SELECT
    tpep_pickup_datetime, tpep_dropoff_datetime,
    CAST(year(tpep_pickup_datetime) * 10000
       + month(tpep_pickup_datetime) * 100
       + day(tpep_pickup_datetime) AS INTEGER),
    pulocationid, dolocationid, payment_type,
    CAST(ratecodeid AS BIGINT), CAST(passenger_count AS BIGINT),
    trip_distance, fare_amount, tip_amount, total_amount,
    "year", "month"
FROM nyc_taxi.yellow_2023_jan

UNION ALL SELECT
    tpep_pickup_datetime, tpep_dropoff_datetime,
    CAST(year(tpep_pickup_datetime) * 10000
       + month(tpep_pickup_datetime) * 100
       + day(tpep_pickup_datetime) AS INTEGER),
    pulocationid, dolocationid, payment_type,
    ratecodeid, passenger_count,
    trip_distance, fare_amount, tip_amount, total_amount,
    "year", "month"
FROM nyc_taxi.yellow_2023_rest

UNION ALL SELECT
    tpep_pickup_datetime, tpep_dropoff_datetime,
    CAST(year(tpep_pickup_datetime) * 10000
       + month(tpep_pickup_datetime) * 100
       + day(tpep_pickup_datetime) AS INTEGER),
    pulocationid, dolocationid, payment_type,
    ratecodeid, passenger_count,
    trip_distance, fare_amount, tip_amount, total_amount,
    "year", "month"
FROM nyc_taxi.yellow_2024_onward;


-- =========================================================================
-- SECTION 3b -- Aggregate rollup
--
-- Pre-aggregates the fact to date x zone x payment_type. Everything a
-- dashboard asks -- trips, revenue, tips, by day/zone/borough/weekend --
-- is answerable from this table instead of the 198M-row fact.
--
--   217,762,236 trips -> 1,371,906 rows   (159x fewer)
--   3.60 GB           -> ~23 MB           (~155x smaller)
--
-- Measured effect on real queries:
--   top zones, one year     36.12 MB -> 0.69 MB   ( 52x cheaper)
--   weekday vs weekend     202.08 MB -> 0.48 MB   (421x cheaper)
--
-- Build cost was $0.0092 (1.886 GB scanned, 5.4 s). It repays that in about
-- ten dashboard refreshes.
--
-- Store SUM and COUNT, never AVG: sums are additive, averages are not. An
-- average of daily averages is not the period average unless every day has
-- identical volume. Derive averages downstream as SUM(total_tip)/SUM(trips).
--
-- partitioned_by columns MUST come last in the SELECT list -- Athena assigns
-- partitions positionally from the end, so putting "year" earlier silently
-- partitions by the wrong column. Athena also caps CTAS at 100 partitions;
-- partitioning by year gives 5, so there is plenty of headroom. Partitioning
-- by year+month would give 60, still fine.
--
-- CTAS cannot append. When new months land, this table must be rebuilt:
-- clear s3://<bucket>/curated/agg_daily_zone/, DROP TABLE, re-run. (An
-- INSERT INTO on the existing table is the incremental alternative.)
--
-- Verify after any rebuild: SUM(trips) here must equal COUNT(*) on
-- fact_trips -- currently 217,762,236.
-- =========================================================================

CREATE TABLE nyc_taxi.agg_daily_zone
WITH (
    format            = 'PARQUET',
    partitioned_by    = ARRAY['year'],
    external_location = 's3://nyc-taxi-bucket-351205763668/curated/agg_daily_zone/'
) AS
SELECT
    pickup_date_key,
    pickup_location_id,
    payment_type,
    COUNT(*)                                AS trips,
    COUNT(*) FILTER (WHERE tip_amount > 0)  AS tipped_trips,
    ROUND(SUM(fare_amount), 2)              AS total_fare,
    ROUND(SUM(tip_amount), 2)               AS total_tip,
    ROUND(SUM(total_amount), 2)             AS total_revenue,
    ROUND(SUM(trip_distance), 2)            AS total_distance,
    "year"
FROM nyc_taxi.fact_trips
GROUP BY pickup_date_key, pickup_location_id, payment_type, "year";


-- =========================================================================
-- SECTION 4 -- Example queries
--
-- Always filter on year/month. Pruning only triggers on PARTITION columns:
-- a predicate on tpep_pickup_datetime returns the same rows but reads every
-- file, because Athena cannot know what is inside a file without opening it.
-- Watch "Data scanned" in the console to confirm.
-- =========================================================================

-- Trips per pickup zone -- straight from the fact (36 MB).
SELECT d.zone, COUNT(*) AS trips
FROM nyc_taxi.fact_trips f
LEFT JOIN nyc_taxi.dim_location d ON f.pickup_location_id = d.location_id
WHERE f.year = 2025
GROUP BY d.zone
ORDER BY trips DESC
LIMIT 10;


-- The same answer from the rollup (0.69 MB). Prefer this shape for anything
-- a dashboard runs repeatedly. Note SUM(a.trips), not COUNT(*) -- each row
-- here already represents many trips.
SELECT l.zone, SUM(a.trips) AS trips
FROM nyc_taxi.agg_daily_zone a
LEFT JOIN nyc_taxi.dim_location l ON a.pickup_location_id = l.location_id
WHERE a.year = 2025
GROUP BY l.zone
ORDER BY trips DESC
LIMIT 10;


-- Monthly revenue and observed tip rate by borough, from the rollup.
-- Averages are derived from the stored sums, never averaged from averages.
SELECT
    d."year",
    d."month",
    l.borough,
    SUM(a.trips)                                            AS trips,
    ROUND(SUM(a.total_revenue), 2)                          AS revenue,
    ROUND(SUM(a.total_tip) / NULLIF(SUM(a.trips), 0), 2)    AS avg_tip_per_trip,
    ROUND(100.0 * SUM(a.tipped_trips) / NULLIF(SUM(a.trips), 0), 2) AS pct_tipped
FROM nyc_taxi.agg_daily_zone a
JOIN nyc_taxi.dim_date     d ON a.pickup_date_key    = d.date_key
JOIN nyc_taxi.dim_location l ON a.pickup_location_id = l.location_id
WHERE a.year = 2025
GROUP BY d."year", d."month", l.borough
ORDER BY d."month", revenue DESC;


-- Share of trips with a recorded tip.
--
-- CAVEAT: cash tips are never recorded by the meter -- payment_type = 2 has
-- an average tip of exactly $0.00 across all 198M rows. The unfiltered number
-- therefore understates real tipping. Restricting to credit card measures
-- "of trips where a tip COULD be observed, how many had one", which is the
-- defensible version of this metric.
SELECT
    ROUND(100.0 * COUNT(*) FILTER (WHERE tip_amount != 0) / COUNT(*), 2) AS pct_tipped
FROM nyc_taxi.fact_trips
WHERE year = 2025
  AND payment_type = 1;


-- Weekday vs weekend.
--
-- The third column is not decoration: a LEFT JOIN keeps rows whose pickup
-- date falls outside dim_date's range (TLC ships a few records with corrupt
-- timestamps), and those get is_weekend = NULL, satisfying neither filter.
-- Counting them makes the leakage visible instead of silent -- 2025 has 8.
SELECT
    COUNT(*) FILTER (WHERE dd.is_weekend = false) AS weekday_trips,
    COUNT(*) FILTER (WHERE dd.is_weekend)         AS weekend_trips,
    COUNT(*) FILTER (WHERE dd.is_weekend IS NULL) AS unmatched_dates
FROM nyc_taxi.fact_trips f
LEFT JOIN nyc_taxi.dim_date dd ON f.pickup_date_key = dd.date_key
WHERE f.year = 2025;


-- Full four-dimension star join.
SELECT
    p.payment_desc,
    r.rate_code_desc,
    l.borough,
    d.is_weekend,
    COUNT(*)                     AS trips,
    ROUND(AVG(f.tip_amount), 2)  AS avg_tip
FROM nyc_taxi.fact_trips f
LEFT JOIN nyc_taxi.dim_payment   p ON f.payment_type       = p.payment_type
LEFT JOIN nyc_taxi.dim_rate_code r ON f.rate_code_id       = r.rate_code_id
LEFT JOIN nyc_taxi.dim_location  l ON f.pickup_location_id = l.location_id
LEFT JOIN nyc_taxi.dim_date      d ON f.pickup_date_key    = d.date_key
WHERE f.year = 2025 AND f.month = 6
GROUP BY 1, 2, 3, 4
ORDER BY trips DESC
LIMIT 20;


-- Hourly demand anomalies -- each hour-of-day judged against its own history
-- across all five years, rather than against the daily average (which would
-- just rediscover rush hour).
WITH hourly AS (
    SELECT
        date_trunc('hour', pickup_time) AS hour_bucket,
        EXTRACT(HOUR FROM pickup_time)  AS hour_of_day,
        COUNT(*)                        AS trips
    FROM nyc_taxi.fact_trips
    WHERE year BETWEEN 2021 AND 2025
    GROUP BY 1, 2
)
SELECT * FROM (
    SELECT
        hour_bucket,
        hour_of_day,
        trips,
        (trips - AVG(trips) OVER (PARTITION BY hour_of_day))
              / NULLIF(STDDEV(trips) OVER (PARTITION BY hour_of_day), 0) AS z
    FROM hourly
) t
ORDER BY ABS(z) DESC
LIMIT 20;
