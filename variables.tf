variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-2"
}

variable "s3_bucket_module_version" {
  type        = string
  default     = "3.0.0"
}

variable "glue_version" {
  type        = string
  description = "The version of glue to use"
  default     = "2.0"
}

variable "bucket_scripts" {
  type        = string
  description = "Glue scripts src bucket"
  default     = "glue-scripts"
}

variable "bucket_raw" {
  type        = string
  description = "Raw data bucket"
  default     = "raw"
}

variable "bucket_curated" {
  type        = string
  description = "Curated data bucket"
  default     = "curated"
}

variable "bucket_consumable" {
  type        = string
  description = "Consumable data bucket"
  default     = "consumable"
}

variable "bucket_error" {
  type        = string
  description = "Bucket for storing data that were failed to process"
  default     = "error"
}

variable "glue_job_name" {
  type        = string
  default     = "test-payment-job"
}

variable "glue_database_name" {
  type        = string
  default     = "playground"
}

variable "glue_table_urls" {
  type        = string
  default     = "urls"
}

variable "glue_crawler_name" {
  type        = string
  default     = "test-payment-crawler"
}

variable "glue_workers_default" {
  type        = number
  default     = 2
}

variable "glue_retries_default" {
  type        = number
  default     = 1
}

variable "python_version_default" {
  type        = number
  default     = 3
}

variable "iam_allow_consumable_read_name" {
  type        = string
  default     = "allow-consumable-read"
}

variable "state-machine-name" {
  type        = string
  default     = "test-payment"
}
