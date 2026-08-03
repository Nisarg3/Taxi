# The Glue Data Catalog database is a namespace only -- it stores no data and
# has no location. The 12 table definitions inside it are managed as SQL in
# ../SQL/athena_setup.sql rather than as aws_glue_catalog_table resources:
# table DDL belongs in SQL (or dbt), infrastructure belongs in Terraform.
resource "aws_glue_catalog_database" "taxi" {
  name        = var.database_name
  description = "NYC yellow taxi lakehouse"
}
