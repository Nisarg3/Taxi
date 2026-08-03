resource "aws_s3_bucket" "lake" {
  bucket = var.bucket_name

  # Refuse to delete a bucket that still holds objects.
  force_destroy = false

  # Belt and braces: terraform destroy will error rather than remove this.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket = aws_s3_bucket.lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 (AES256), not SSE-KMS. A KMS key costs $1/month plus per-request
# charges; SSE-S3 is encryption at rest for free.
resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    # Note: the live rule was created in the console with a leading space in
    # its ID. Declaring it clean here means the first apply normalises it.
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    # Query output is disposable -- regenerate it by re-running the query.
    expiration {
      days = 7
    }

    # Failed multipart uploads keep their chunks and BILL for them, while
    # staying invisible in the object listing. This sweeps them up.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
