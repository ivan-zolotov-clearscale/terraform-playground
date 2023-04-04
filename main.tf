locals {
  enabled                   = module.this.enabled
  produce_parquet_py        = "produce_parquet.py"
  consumable_data_path      = "s3://${module.s3_bucket_cosumable.bucket_id}}/"
}

data "aws_caller_identity" "current" {}

# Source S3 bucket to store Glue Job scripts
module "s3_bucket_scripts" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_scripts}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true
  allow_encrypted_uploads_only = true
  allow_ssl_requests_only      = true
  block_public_acls            = true
  block_public_policy          = true
  ignore_public_acls           = true
  restrict_public_buckets      = true

  context    = module.this.context
}

resource "aws_s3_object" "job_script" {
  count = local.enabled ? 1 : 0

  bucket        = module.s3_bucket_scripts.bucket_id
  key           = local.produce_parquet_py
  source        = "${path.module}/scripts/${local.produce_parquet_py}"
  force_destroy = true

  tags = module.this.tags
}

# Destination S3 bucket to store Glue Job results
module "s3_bucket_raw" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_raw}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}

module "s3_bucket_curated" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_curated}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}

module "s3_bucket_cosumable" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_consumable}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}

module "s3_bucket_error" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_error}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}


module "glue_database_playground" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-catalog-database"
  version = "0.3.0"

  catalog_database_name        = "${terraform.workspace}-${var.glue_database_name}"
  location_uri                 = local.consumable_data_path

  context = module.this.context
}

module "glue_table_urls" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-catalog-table"
  version = "0.3.0"

  catalog_table_name        = "${terraform.workspace}-${var.glue_table_urls}"
  database_name             = module.glue_database_playground.name

  storage_descriptor = {
    location = local.consumable_data_path
  }

  context = module.this.context
}

module "glue_crawler" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-crawler"
  version = "0.3.0"

  database_name       = module.glue_database_playground.name
  role                = module.iam_role.arn
//  schedule            = "cron(0 1 * * ? *)"
  crawler_name        = "urls-crawler"

  schema_change_policy = {
    delete_behavior = "LOG"
    update_behavior = null
  }

  catalog_target = [
    {
      database_name = module.glue_database_playground.name
      tables        = [module.glue_table_urls.name]
    }
  ]

  context = module.this.context

}

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "AllowS3Read"
    effect    = "Allow"
    resources = ["arn:aws:s3:::${module.s3_bucket_cosumable.bucket_id}/*"]

    // TODO atomic access required
    actions = [
      "s3:*"
    ]
  }
}

module "iam_role" {
  source  = "registry.terraform.io/cloudposse/iam-role/aws"
  version = "0.17.0"
  name    = "${terraform.workspace}-${var.iam_allow_consumable_read_name}"

  principals = {
    "Service" = ["glue.amazonaws.com"]
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
  ]
//
  policy_documents = [
    data.aws_iam_policy_document.s3_access.json
  ]

  context = module.this.context
  role_description = "Allow Glue job to read data from consumable bucket"
}

module "glue_job" {
  #source = "cloudposse/glue/aws//modules/glue-job"
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-job"

  job_name          = "${terraform.workspace}-${var.glue_job_name}"
  job_description   = "Glue Job that runs data_cleaning.py Python script"
  role_arn          = module.iam_role.arn
  glue_version      = var.glue_version
  worker_type       = "Standard"
  number_of_workers = var.glue_workers_default
  max_retries       = var.glue_retries_default

  # The job timeout in minutes
  timeout = 20

  command = {
    # The name of the job command. Defaults to `glueetl`.
    # Use `pythonshell` for Python Shell Job Type, or `gluestreaming` for Streaming Job Type.
    name            = "glueetl"
    script_location = "s3://${module.s3_bucket_scripts.bucket_id}/${local.produce_parquet_py}"
    python_version  = var.python_version_default
  }

  context = module.this.context
}

module "step_function" {
  source = "registry.terraform.io/terraform-aws-modules/step-functions/aws"

  name       = "${terraform.workspace}-playground"
  definition = <<EOF
{
  "Comment": "A Hello World example of the Amazon States Language using Pass states",
  "StartAt": "StartCrawler",
  "States": {
    "StartCrawler": {
      "Type": "Task",
      "Parameters": {
        "Name": "${module.glue_crawler.name}"
      },
      "Resource": "arn:aws:states:::aws-sdk:glue:startCrawler",
      "Next": "StartGlueJob"
    },
    "StartGlueJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${module.glue_job.name}"
      },
      "End": true
    }
  }
}
EOF

  service_integrations = {
    glue_Sync = {
      glue = [module.glue_job.arn]
    }
  }

  attach_policy_statements = true
  policy_statements = {
    glue_crawler = {
      effect    = "Allow",
      actions   = ["glue:StartCrawler"],
      resources = ["${module.glue_crawler.arn}"]
    }
  }

  type = "STANDARD"

}
