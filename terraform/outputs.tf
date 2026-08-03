output "bucket_name" {
  description = "S3 bucket backing the lakehouse"
  value       = aws_s3_bucket.lake.id
}

output "glue_database" {
  description = "Glue catalog database holding the table definitions"
  value       = aws_glue_catalog_database.taxi.name
}

output "athena_workgroup" {
  description = "Select this in the Athena console to get the scan ceiling"
  value       = aws_athena_workgroup.taxi.name
}

output "raw_prefix" {
  description = "Where the ingest script writes partitioned parquet"
  value       = "s3://${aws_s3_bucket.lake.id}/raw/yellow/"
}

output "curated_prefix" {
  description = "Where CTAS output lands"
  value       = "s3://${aws_s3_bucket.lake.id}/curated/"
}
