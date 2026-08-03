# The one resource Terraform actually creates here (everything else is
# adopted). A dedicated workgroup gives you a per-query scan ceiling, which
# is the only hard cost guardrail Athena offers.
resource "aws_athena_workgroup" "taxi" {
  name        = "taxi"
  description = "Taxi lakehouse queries, with a per-query scan ceiling"

  configuration {
    # Force these settings on every query, even if a client asks otherwise.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # 2 GiB ceiling. A query that would scan more is CANCELLED rather than
    # billed -- the guardrail against a stray SELECT * over 198M rows.
    # Minimum permitted value is 10 MB.
    bytes_scanned_cutoff_per_query = 2147483648

    result_configuration {
      output_location = "s3://${var.bucket_name}/athena-results/"
    }
  }
}
