# Brownfield adoption: these resources already exist (created by hand in the
# console and CLI), so Terraform must adopt them rather than create them.
#
# These are import BLOCKS (Terraform 1.5+), not the legacy `terraform import`
# CLI command. They appear in `terraform plan`, so you can preview exactly
# what will be adopted before touching state, and they are reviewable in a PR.
#
# Each resource type has its own import ID format -- see the "Import" section
# at the bottom of each resource's provider documentation page.
#
# Once the import has been applied, this file can be deleted; the state then
# holds the mapping. Leaving it in place is harmless (imports are a no-op once
# the resource is already in state).

import {
  to = aws_s3_bucket.lake
  id = "nyc-taxi-bucket-351205763668"
}

import {
  to = aws_s3_bucket_public_access_block.lake
  id = "nyc-taxi-bucket-351205763668"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.lake
  id = "nyc-taxi-bucket-351205763668"
}

import {
  to = aws_s3_bucket_lifecycle_configuration.lake
  id = "nyc-taxi-bucket-351205763668"
}

# Glue import ID is "<catalog-id>:<database-name>", where catalog-id is the
# AWS account ID.
import {
  to = aws_glue_catalog_database.taxi
  id = "351205763668:nyc_taxi"
}
