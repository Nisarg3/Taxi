# ---------------------------------------------------------------------------
# Scheduled ingest: EventBridge -> Lambda -> S3
#
# Everything here sits inside AWS's ALWAYS-free tiers (not the 12-month ones):
#   Lambda       1M requests + 400,000 GB-seconds per month
#   EventBridge  scheduled rules are free
#   CloudWatch   5 GB log ingestion per month
#
# One monthly run at 512 MB for ~60s is about 30 GB-seconds. The free
# allowance is 400,000. This will not cost anything.
# ---------------------------------------------------------------------------

# Zip the source at plan time. No build step, no CI, no artifact bucket --
# the function is a single stdlib-only file and boto3 ships in the runtime.
data "archive_file" "ingest" {
  type        = "zip"
  source_file = "${path.module}/../lambda/ingest_month.py"
  output_path = "${path.module}/build/ingest_month.zip"
}

# --- IAM -------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "taxi-ingest-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: write only under the raw prefix, and only the two actions
# the function actually calls. No s3:DeleteObject, no bucket-wide access.
data "aws_iam_policy_document" "ingest" {
  statement {
    sid    = "WriteRawPrefix"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.lake.arn}/raw/yellow/*"]
  }

  statement {
    sid       = "HeadObjectNeedsListOnBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/yellow/*"]
    }
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "taxi-ingest-policy"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

# --- Function --------------------------------------------------------------

# Declared explicitly (rather than letting Lambda auto-create it) so the
# retention is bounded. Auto-created groups keep logs forever and slowly eat
# into the 5 GB CloudWatch free tier.
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/taxi-ingest"
  retention_in_days = 14
}

resource "aws_lambda_function" "ingest" {
  function_name = "taxi-ingest"
  role          = aws_iam_role.ingest.arn

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  handler = "ingest_month.handler"
  runtime = "python3.12"

  # The work is network-bound, not CPU-bound, but Lambda scales network and
  # CPU with memory -- 512 MB uploads meaningfully faster than 128 MB, and
  # finishing sooner costs fewer GB-seconds. Streaming to S3 means actual
  # memory use stays flat regardless of file size.
  memory_size = 512
  timeout     = 300

  environment {
    variables = {
      BUCKET = aws_s3_bucket.lake.id
      PREFIX = "raw/yellow"

      # Must exceed MAX_UPLOADS * (months between runs) or backlog ages out
      # of the window before it can be ingested. At 3 uploads per monthly run,
      # 6 was too short -- a 5-month backlog would have lost its oldest two
      # months. 12 gives a year of self-healing.
      LOOKBACK = "12"

      # Caps runtime per invocation: 3 files x ~60 MB well inside the 300s
      # timeout, even on a slow fetch.
      MAX_UPLOADS = "3"
    }
  }

  depends_on = [
    aws_iam_role_policy.ingest,
    aws_cloudwatch_log_group.ingest,
  ]
}

# --- Schedule --------------------------------------------------------------

# TLC publishes roughly two months in arrears, so a monthly check is plenty.
# The 6-month lookback window means a missed run self-heals on the next one.
resource "aws_cloudwatch_event_rule" "monthly" {
  name                = "taxi-ingest-monthly"
  description         = "Check TLC for newly published yellow-taxi months"
  schedule_expression = "cron(0 6 5 * ? *)" # 06:00 UTC on the 5th
}

resource "aws_cloudwatch_event_target" "ingest" {
  rule      = aws_cloudwatch_event_rule.monthly.name
  target_id = "taxi-ingest"
  arn       = aws_lambda_function.ingest.arn
}

# EventBridge cannot invoke the function without this -- the rule existing is
# not enough. Forgetting it produces a schedule that silently never fires.
resource "aws_lambda_permission" "events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly.arn
}
