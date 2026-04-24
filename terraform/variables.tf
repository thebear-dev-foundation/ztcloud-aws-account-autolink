variable "region" {
  description = "AWS region where the reconciler Lambda, StackSet admin, and EventBridge rules are deployed. Typically the Audit account's home region."
  type        = string
  default     = "us-east-1"
}

variable "target_region" {
  description = "AWS region where the ZscalerTagDiscoveryRoleBasic is deployed in target workload accounts, and the region Zscaler discovers resources in."
  type        = string
  default     = "ap-southeast-2"
}

variable "pipeline_name" {
  description = "CodePipeline name whose stage-transition events trigger the reconciler. Default is the LZA Accelerator pipeline name."
  type        = string
  default     = "AWSAccelerator-Pipeline"
}

variable "stage_name" {
  description = "Pipeline stage whose SUCCEEDED state triggers reconciliation. LZA uses 'Accounts' for the account-vending stage."
  type        = string
  default     = "Accounts"
}

variable "zs_secret_id" {
  description = "Secrets Manager secret ID holding the Zscaler OneAPI credentials (vanity, client_id, client_secret)."
  type        = string
  default     = "zscaler/oneapi-creds"
}

variable "ztw_region_id" {
  description = "Zscaler numeric region ID. Obtain via GET /ztw/api/v1/publicCloudInfo/supportedRegions."
  type        = number
  default     = 1178338
}

variable "ztw_region_name" {
  description = "Zscaler region enum name. Must match the ID above."
  type        = string
  default     = "AP_SOUTHEAST_2"
}

variable "opt_in_tag_key" {
  description = "AWS Organizations tag key used as the opt-in gate for onboarding."
  type        = string
  default     = "zscaler-managed"
}

variable "opt_in_tag_value" {
  description = "AWS Organizations tag value used as the opt-in gate."
  type        = string
  default     = "true"
}

variable "managed_prefix" {
  description = "Name prefix applied to Zscaler Public Cloud Info records created by this module. Offboarding only deletes records that start with this prefix, so pre-existing manually-onboarded accounts are never touched."
  type        = string
  default     = "ZTW-"
}

variable "dry_run" {
  description = "When true, the reconciler logs intended actions but never POSTs to OneAPI, DELETEs from OneAPI, or creates/deletes StackSet instances. Flip to false after verification."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the reconciler's log group."
  type        = number
  default     = 365
}

variable "stackset_name" {
  description = "CloudFormation StackSet name used to ship the Zscaler discovery role into workload accounts."
  type        = string
  default     = "ztw-discovery-role"
}

variable "lambda_name" {
  description = "Reconciler Lambda function name."
  type        = string
  default     = "ztw-reconciler"
}
