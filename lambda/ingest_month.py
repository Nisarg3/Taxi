"""Scheduled ingest of new NYC TLC yellow-taxi months into S3.

Runs on a monthly EventBridge schedule. TLC publishes roughly two months in
arrears, so each run looks back over a window of recent months, finds the ones
missing from S3, and uploads whatever has become available since last time.

Deliberately uses only the standard library plus boto3, which is already
present in the Lambda Python runtime. No dependency layer, no build step, no
packaging -- the whole function is one file Terraform zips at plan time.

The download is streamed straight from HTTP into S3 via upload_fileobj, so the
file never touches Lambda's /tmp and memory stays flat regardless of file size.

Environment:
    BUCKET        target bucket (required)
    PREFIX        key prefix, default "raw/yellow"
    LOOKBACK      months back to examine, default 6
    MAX_UPLOADS   safety cap per invocation, default 3
"""

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import date

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ.get("PREFIX", "raw/yellow")
LOOKBACK = int(os.environ.get("LOOKBACK", "6"))
MAX_UPLOADS = int(os.environ.get("MAX_UPLOADS", "3"))

BASE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"

s3 = boto3.client("s3")


def filename(year, month):
    return f"yellow_tripdata_{year}-{month:02d}.parquet"


def s3_key(year, month):
    # year=/month= prefixes are what Athena's partition projection matches
    # against. The zero-padded month is required -- month=3 matches nothing.
    return f"{PREFIX}/year={year}/month={month:02d}/{filename(year, month)}"


def already_present(key):
    try:
        s3.head_object(Bucket=BUCKET, Key=key)
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey"):
            return False
        raise


def candidate_months(today, lookback):
    """Recent months, newest first. Excludes the current month (never published)."""
    months = []
    y, m = today.year, today.month
    for _ in range(lookback):
        m -= 1
        if m == 0:
            y, m = y - 1, 12
        months.append((y, m))
    return months


def ingest(year, month):
    """Stream one month from TLC into S3. False if not published yet."""
    key = s3_key(year, month)
    url = f"{BASE_URL}/{filename(year, month)}"
    try:
        with urllib.request.urlopen(url, timeout=120) as resp:
            # Non-seekable stream; upload_fileobj chunks it without buffering
            # the whole body, so memory stays flat.
            s3.upload_fileobj(resp, BUCKET, key)
    except urllib.error.HTTPError as exc:
        # CloudFront answers 403 (not 404) for months TLC hasn't released.
        if exc.code in (403, 404):
            log.info("not published yet: %s-%02d", year, month)
            return False
        raise
    log.info("uploaded s3://%s/%s", BUCKET, key)
    return True


def handler(event, context):
    # An explicit {"year": 2025, "month": 1} overrides the scan -- handy for
    # backfills and for testing without waiting for a schedule.
    if event and "year" in event and "month" in event:
        targets = [(int(event["year"]), int(event["month"]))]
    else:
        targets = candidate_months(date.today(), LOOKBACK)

    uploaded, skipped, unpublished = [], [], []

    for year, month in targets:
        if len(uploaded) >= MAX_UPLOADS:
            log.info("hit MAX_UPLOADS=%d, stopping", MAX_UPLOADS)
            break

        key = s3_key(year, month)
        if already_present(key):
            skipped.append(f"{year}-{month:02d}")
            continue

        if ingest(year, month):
            uploaded.append(f"{year}-{month:02d}")
        else:
            unpublished.append(f"{year}-{month:02d}")

    result = {
        "uploaded": uploaded,
        "skipped": skipped,
        "unpublished": unpublished,
    }
    log.info("result %s", json.dumps(result))
    return result
