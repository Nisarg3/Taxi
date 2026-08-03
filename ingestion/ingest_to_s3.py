"""Ingest NYC TLC yellow-taxi parquet files into S3 using Hive-style partitions.

Layout written to S3:
    raw/yellow/year=2021/month=01/yellow_tripdata_2021-01.parquet

That prefix shape is what lets Athena prune partitions -- a query filtered to
one year reads only the keys under year=<that year>/ instead of all 60 files.

The script is idempotent: it checks S3 before doing any work, so re-running it
after a failure only moves the files that are actually missing.

Disk is the binding constraint on this machine (~18 GB free), so downloads go
to a temp dir one file at a time and are deleted immediately after upload.
Files that already exist in LOCAL_DIR are uploaded in place and never deleted.

This is the one-off backfill tool. Ongoing monthly ingest is handled by the
taxi-ingest Lambda (see lambda/ingest_month.py), which does the same job on an
EventBridge schedule.

Usage (from the repo root):
    python ingestion/ingest_to_s3.py --years 2025          # single year
    python ingestion/ingest_to_s3.py --years 2021-2025     # full range
    python ingestion/ingest_to_s3.py --years 2021-2025 --dry-run
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import boto3
import requests
from botocore.exceptions import ClientError

BUCKET = "nyc-taxi-bucket-351205763668"
PREFIX = "raw/yellow"
BASE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"

# Resolved from the file's own location, not the working directory, so the
# script runs correctly from anywhere.
PROJECT_ROOT = Path(__file__).resolve().parents[1]

# Files already downloaded live here; reuse them instead of re-fetching.
LOCAL_DIR = PROJECT_ROOT / "data" / "raw"
TMP_DIR = PROJECT_ROOT / "data" / "_tmp"


def filename(year: int, month: int) -> str:
    return f"yellow_tripdata_{year}-{month:02d}.parquet"


def s3_key(year: int, month: int) -> str:
    return f"{PREFIX}/year={year}/month={month:02d}/{filename(year, month)}"


def already_uploaded(s3, bucket: str, key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey"):
            return False
        raise


def download(url: str, dest: Path) -> bool:
    """Stream a file to disk. Returns False if TLC hasn't published it yet."""
    with requests.get(url, stream=True, timeout=120) as resp:
        if resp.status_code == 403:  # CloudFront returns 403 for missing months
            return False
        resp.raise_for_status()
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as handle:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                handle.write(chunk)
    return True


def parse_years(spec: str) -> list[int]:
    if "-" in spec:
        start, end = spec.split("-", 1)
        return list(range(int(start), int(end) + 1))
    return [int(spec)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--years", default="2021-2025", help="e.g. 2025 or 2021-2025")
    parser.add_argument("--bucket", default=BUCKET)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    bucket = args.bucket
    s3 = boto3.client("s3")
    uploaded = skipped = missing = 0
    bytes_sent = 0

    for year in parse_years(args.years):
        for month in range(1, 13):
            name = filename(year, month)
            key = s3_key(year, month)

            if already_uploaded(s3, bucket, key):
                print(f"  skip     {name}  (already in S3)")
                skipped += 1
                continue

            if args.dry_run:
                print(f"  would upload  {name} -> s3://{bucket}/{key}")
                uploaded += 1
                continue

            # Prefer a copy that is already on disk; only clean up what we fetch.
            local = LOCAL_DIR / name
            fetched = False
            if not local.exists():
                local = TMP_DIR / name
                print(f"  download {name} ...", end=" ", flush=True)
                if not download(f"{BASE_URL}/{name}", local):
                    print("not published, skipping")
                    missing += 1
                    continue
                fetched = True
                print("ok")

            size = local.stat().st_size
            print(f"  upload   {name}  ({size / 1024 / 1024:.1f} MB)")
            s3.upload_file(str(local), bucket, key)
            bytes_sent += size
            uploaded += 1

            if fetched:
                local.unlink()  # keep disk usage flat

    if TMP_DIR.exists() and not any(TMP_DIR.iterdir()):
        TMP_DIR.rmdir()

    print(
        f"\nuploaded={uploaded}  skipped={skipped}  unpublished={missing}"
        f"  transferred={bytes_sent / 1024 / 1024 / 1024:.2f} GB"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
