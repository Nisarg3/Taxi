variable "bucket_name" {
  description = "S3 bucket backing the taxi lakehouse"
  type        = string
  default     = "nyc-taxi-bucket-351205763668"
}

variable "database_name" {
  description = "Glue catalog database holding the table definitions"
  type        = string
  default     = "nyc_taxi"
}

variable "account_id" {
  description = "AWS account ID (used for Glue import IDs)"
  type        = string
  default     = "351205763668"
}
