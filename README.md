# NYC Yellow Taxi Lakehouse

A serverless analytics stack over the NYC TLC yellow-taxi trip records:
**218 million trips, 2021–2026**, queried directly from partitioned parquet in
S3 — no database server, no data warehouse, no cluster.

Total AWS spend to build and run it: **about $0.03**.

## Architecture

```
TLC (CloudFront)
      │
      ├── ingestion/ingest_to_s3.py      one-off backfill, 60 months
      └── lambda/ingest_month.py         monthly, EventBridge-scheduled
      │
      ▼
   S3  raw/yellow/year=YYYY/month=MM/*.parquet     3.6 GB
      │
      ▼
   Glue Data Catalog  (table definitions only — no data)
      │
      ▼
   Athena  ── fact_trips (view) ── 4 dimensions
           └─ agg_daily_zone (CTAS rollup, 23 MB)
      │
      ▼
   dashboard/app.py   Streamlit
```

Storage, metadata, and compute are three separate services. Athena stores
nothing; deleting it would leave every byte of data untouched.

## Layout

| Path | What's in it |
|---|---|
| `ingestion/` | One-off backfill script (60 months → S3) |
| `lambda/` | Scheduled ingest function, stdlib + boto3 only |
| `terraform/` | Bucket, Glue database, Athena workgroup, Lambda, schedule |
| `sql/athena/` | Catalog DDL — the authoritative table definitions |
| `sql/postgres/` | Earlier local-Postgres queries, kept for reference |
| `dashboard/` | Streamlit app querying Athena |
| `notebooks/` | Exploratory analysis |
| `data/raw/` | Local parquet cache — **gitignored**, S3 is canonical |
| `data/reference/` | Zone lookup CSV and shapefiles |
| `docs/` | TLC data dictionary |

## Setup

```bash
python -m venv .venv
.venv\Scripts\activate            # Windows
pip install -r requirements.txt
aws configure                     # region: us-east-2
```

## Running things

**Dashboard**

```bash
.venv\Scripts\streamlit.exe run dashboard/app.py
```

**Backfill more history**

```bash
python ingestion/ingest_to_s3.py --years 2021-2025 --dry-run
python ingestion/ingest_to_s3.py --years 2021-2025
```

Idempotent — it checks S3 first, so re-running after a failure only moves
what's missing.

**Infrastructure**

```bash
cd terraform
terraform plan       # always safe, read-only
terraform apply
```

Do **not** run `terraform destroy`. The bucket is protected by
`prevent_destroy`, but the Glue database is not, and destroying it drops all
12 table definitions.

## Design decisions worth knowing

**Partition projection, not a Glue Crawler.** Athena computes partitions from
rules in `TBLPROPERTIES` rather than storing them in the catalog. Free, never
stale, no `MSCK REPAIR`. The catch: `projection.month.digits = '2'` is
load-bearing — without it Athena generates `month=3`, matches nothing, and
every query silently returns zero rows.

**Always filter on `year`/`month`.** Pruning only triggers on partition
columns. A predicate on `tpep_pickup_datetime` returns identical rows while
reading every file.

**Schema drift is handled by era-scoped tables.** TLC changed `ratecodeid` and
`passenger_count` from `double` to `int64` at the **2023-02** file, and Athena
cannot coerce between them — a mismatched read fails with `HIVE_BAD_DATA`.
Four raw tables cover the eras and `fact_trips` unions them with a cast. 2023
needs two tables because projection ranges are a rectangular year×month
product and can't express "up to January of one year".

**`fact_trips` is a view, not a table.** The source is already parquet and
already partitioned, so materialising it would copy ~3.6 GB to produce
equivalent data. Views cost nothing. The dimensions *are* CTAS tables, because
those involve real transformation.

**`agg_daily_zone` earns its storage.** 218M rows → 1.37M rows, 3.6 GB → 23 MB.
Dashboard queries drop from 202 MB to 0.5 MB. It repaid its build cost in about
ten refreshes. Note that CTAS cannot append — new months require a rebuild.

## Analytical caveat that matters

**Cash tips are never recorded.** Across 32.7M cash trips the recorded tip rate
is **0.024%** — the meter simply doesn't capture them. Any tipping metric that
doesn't filter to `payment_type = 1` is measuring payment mix.

Filtering to card raises the overall rate from 60.7% to **94.4%**. But it does
*not* flatten the borough differences: card-only tip rates still run from
**6.3% in the Bronx** to **95.6% in Manhattan**. Payment mix explains part of
that gap, not all of it, and the cause of the remainder is unresolved. Treat it
as a lead, not a finding — the volumes are wildly unequal (0.4M Bronx card
trips against 140M in Manhattan).

## Known issues

- **`.git` is ~1.1 GB.** 791 MB of parquet was committed before `.gitignore`
  existed. Ignoring them fixes new commits but not history; purging requires
  `git filter-repo` and a force-push.
- **The rollup goes stale** when the Lambda ingests a new month. Rebuilding is
  currently manual. A Step Functions state machine doing `INSERT INTO` for the
  new partition would close the loop.
