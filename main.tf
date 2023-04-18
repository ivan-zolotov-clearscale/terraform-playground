locals {
  enabled                   = module.this.enabled
  data                      = "data"
  scripts                   = "scripts"
  produce_curated_py        = "produce_curated.py"
  produce_consumable_py     = "produce_consumable.py"
  fargate                   = "FARGATE"
}

data "aws_caller_identity" "current" {}

# Source S3 bucket to store Glue Job scripts
module "s3_bucket_scripts" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"
  // TODO rename to follow convention aws-glue-assets
  name                         = "aws-glue-${terraform.workspace}-${data.aws_caller_identity.current.account_id}-${var.bucket_scripts}"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}

resource "aws_s3_object" "job_script_produce_curated" {
  count = local.enabled ? 1 : 0

  bucket        = module.s3_bucket_scripts.bucket_id
  key           = local.produce_curated_py
  source        = "${path.module}/${local.scripts}/${local.produce_curated_py}"
  force_destroy = true

  tags = module.this.tags
}

resource "aws_s3_object" "job_script_produce_consumable" {
  count = local.enabled ? 1 : 0

  bucket        = module.s3_bucket_scripts.bucket_id
  key           = local.produce_consumable_py
  source        = "${path.module}/${local.scripts}/${local.produce_consumable_py}"
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

module "s3_bucket_athena_queries" {
  source  = "registry.terraform.io/cloudposse/s3-bucket/aws"
  version = "3.0.0"

  name                         = "${terraform.workspace}-${data.aws_caller_identity.current.account_id}-athena-queries"
  acl                          = "private"
  versioning_enabled           = false
  force_destroy                = true

  context    = module.this.context
}


module "glue_database_playground" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-catalog-database"
  version = "0.3.0"

  catalog_database_name        = "${terraform.workspace}_${var.glue_database_name}"
  location_uri                 = "s3://${module.s3_bucket_raw.bucket_id}/input"

  context = module.this.context
}

module "glue_table_urls" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-catalog-table"
  version = "0.3.0"

  catalog_table_name        = "${terraform.workspace}_${var.glue_table_urls}"
  database_name             = module.glue_database_playground.name

  storage_descriptor = {
    location = "s3://${module.s3_bucket_cosumable.bucket_id}/${local.data}"
  }

  context = module.this.context
}

module "glue_crawler" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-crawler"
  version = "0.3.0"

  database_name       = module.glue_database_playground.name
  role                = module.glue_iam_role.arn
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

data "aws_iam_policy_document" "s3_data_access" {
  statement {
    sid       = "AllowS3Read"
    effect    = "Allow"
    resources = [
      "arn:aws:s3:::${module.s3_bucket_raw.bucket_id}/*",
      "arn:aws:s3:::${module.s3_bucket_error.bucket_id}/*",
      "arn:aws:s3:::${module.s3_bucket_curated.bucket_id}/*",
      "arn:aws:s3:::${module.s3_bucket_cosumable.bucket_id}/*"
    ]

    // TODO atomic access required
    actions = [
      "s3:*"
    ]
  }
}

module "glue_iam_role" {
  source  = "registry.terraform.io/cloudposse/iam-role/aws"
  version = "0.17.0"
  name    = "${terraform.workspace}-glue-job-s3-access"

  principals = {
    "Service" = ["glue.amazonaws.com"]
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
  ]
//
  policy_documents = [
    data.aws_iam_policy_document.s3_data_access.json
  ]

  context = module.this.context
  role_description = "Allow Glue job to read data from consumable bucket"
}

module "glue_job_produce_curated" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-job"

  job_name          = "${terraform.workspace}-produce-curated"
  role_arn          = module.glue_iam_role.arn
  glue_version      = var.glue_version
  worker_type       = var.glue_worker_standard
  number_of_workers = var.glue_workers_default
  max_retries       = var.glue_retries_default
  default_arguments = {
    "--input-path" = "s3://${module.s3_bucket_raw.bucket_id}/${local.data}/",
    "--output-path" = "s3://${module.s3_bucket_curated.bucket_id}/${local.data}/"
    "--error-path" = "s3://${module.s3_bucket_error.bucket_id}/${local.data}/"
  }
  timeout = var.glue_timeout_default
  command = {
    name            = var.glue_etl
    script_location = "s3://${module.s3_bucket_scripts.bucket_id}/${local.produce_curated_py}"
    python_version  = var.python_version_default
  }

  context = module.this.context
}

module "glue_job_produce_consumable" {
  source = "registry.terraform.io/cloudposse/glue/aws//modules/glue-job"

  job_name          = "${terraform.workspace}-produce-consumable"
  role_arn          = module.glue_iam_role.arn
  glue_version      = var.glue_version
  worker_type       = var.glue_worker_standard
  number_of_workers = var.glue_workers_default
  max_retries       = var.glue_retries_default
  default_arguments = {
    "--input-path" = "s3://${module.s3_bucket_curated.bucket_id}/${local.data}/",
    "--output-path" = "s3://${module.s3_bucket_cosumable.bucket_id}/${local.data}/"
    "--error-path" = "s3://${module.s3_bucket_error.bucket_id}/${local.data}/"
  }
  timeout = var.glue_timeout_default
  command = {
    name            = var.glue_etl
    script_location = "s3://${module.s3_bucket_scripts.bucket_id}/${local.produce_consumable_py}"
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
  "StartAt": "StartCreateCuratedGlueJob",
  "States": {
    "StartCreateCuratedGlueJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${module.glue_job_produce_curated.name}"
      },
      "Next": "StartCreateConsumableGlueJob"
    },
    "StartCreateConsumableGlueJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${module.glue_job_produce_consumable.name}"
      },
      "Next": "StartCrawler"
    },
    "StartCrawler": {
      "Type": "Task",
      "Parameters": {
        "Name": "${module.glue_crawler.name}"
      },
      "Resource": "arn:aws:states:::aws-sdk:glue:startCrawler",
      "End": true
    }
  }
}
EOF

  service_integrations = {
    glue_Sync = {
      glue = [
        module.glue_job_produce_curated.arn,
        module.glue_job_produce_consumable.arn
      ]
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

module "vpc" {
  source = "registry.terraform.io/terraform-aws-modules/vpc/aws"

  name = "${terraform.workspace}-playground"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a"]
//  public_subnets  = ["10.0.0.0/24"]
  private_subnets = ["10.0.0.0/16"]

  map_public_ip_on_launch = true
  manage_default_security_group  = true

  enable_nat_gateway = false
  enable_vpn_gateway = false

}

module "vpc_endpoints" {
  source  = "registry.terraform.io/terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 3.0"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [module.vpc_endpoint_security_group.security_group_id]

  endpoints = {
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }

}

module "vpc_endpoint_security_group" {
  source  = "registry.terraform.io/terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${terraform.workspace}-vpc-endpoint"
  vpc_id      = module.vpc.vpc_id

  ingress_with_self = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "Container to VPC endpoint service"
      self        = true
    },
  ]

  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["https-443-tcp"]

}

module "batch" {
  source = "registry.terraform.io/terraform-aws-modules/batch/aws"

  instance_iam_role_name = "${terraform.workspace}-ecs-instance"
  service_iam_role_name  = "${terraform.workspace}-batch"

  compute_environments = {
    fargate = {
      name_prefix = "${terraform.workspace}-playground"

      compute_resources = {
        type      = local.fargate
        max_vcpus = 21

        security_group_ids = [module.vpc.default_security_group_id]
        subnets            = module.vpc.private_subnets
      }
    }
  }

  job_queues = {
    low_priority = {
      name     = "${terraform.workspace}-playground"
      state    = "ENABLED"
      priority = 1
    }
  }

  job_definitions = {
    run_athena_query = {
      name                  = "${terraform.workspace}-run-athena-query"
      propagate_tags        = true
      platform_capabilities = [local.fargate]

      container_properties = jsonencode({
        command = ["python3", "script.py", "--placeholders", "{\"limit\": 10}"]
        image   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/batch-playground:latest"
        fargatePlatformConfiguration = {
          platformVersion = "LATEST"
        },
        networkConfiguration = {
          assignPublicIp = "ENABLED"
        }
        resourceRequirements = [
          { type = "VCPU", value = "1" },
          { type = "MEMORY", value = "2048" }
        ],
        executionRoleArn = aws_iam_role.ecs_task_execution_role.arn
        jobRoleArn = aws_iam_role.ecs_task_execution_role.arn
      })

      attempt_duration_seconds = 60
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${terraform.workspace}-ecs-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_role.json

}

data "aws_iam_policy_document" "ecs_task_execution_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
//  statement {
//    sid       = "AllowS3Read"
//    effect    = "Allow"
//    actions = [
//      "s3:*"
//    ]
//
//    resources = [
//      "*"
//    ]
//  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "s3_full_access" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "athena_full_access" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonAthenaFullAccess"
}
