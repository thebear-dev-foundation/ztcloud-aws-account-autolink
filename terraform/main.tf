terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

data "aws_caller_identity" "self" {}

# ========== CloudFormation StackSet for the Zscaler discovery role ==========
#
# Service-managed StackSet — requires AWS Organizations trusted access for CloudFormation,
# enabled out-of-band via:
#   aws organizations enable-aws-service-access --service-principal member.org.stacksets.cloudformation.amazonaws.com
#   aws cloudformation activate-organizations-access
resource "aws_cloudformation_stack_set" "discovery_role" {
  name             = var.stackset_name
  description      = "Deploys ZscalerTagDiscoveryRoleBasic into opted-in workload accounts"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  template_body    = file("${path.module}/discovery_role.yaml")

  auto_deployment {
    enabled                          = false
    retain_stacks_on_account_removal = false
  }

  parameters = {
    ExternalId = "placeholder-overridden-per-instance"
  }

  operation_preferences {
    max_concurrent_count    = 1
    failure_tolerance_count = 0
    region_concurrency_type = "SEQUENTIAL"
  }

  lifecycle {
    ignore_changes = [parameters, administration_role_arn]
  }
}

# ========== Reconciler Lambda ==========
resource "aws_iam_role" "reconciler" {
  name = "${var.lambda_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.reconciler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "reconciler_inline" {
  role = aws_iam_role.reconciler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "OrgRead"
        Effect = "Allow"
        Action = [
          "organizations:ListAccounts",
          "organizations:ListTagsForResource",
          "organizations:DescribeAccount",
          "organizations:ListRoots"
        ]
        Resource = "*"
      },
      {
        Sid = "SecretRead"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.self.account_id}:secret:${var.zs_secret_id}-*"
      },
      {
        Sid = "StackSetOps"
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStackInstances",
          "cloudformation:DeleteStackInstances",
          "cloudformation:DescribeStackSetOperation",
          "cloudformation:DescribeStackSet",
          "cloudformation:ListStackInstances"
        ]
        Resource = "arn:aws:cloudformation:*:${data.aws_caller_identity.self.account_id}:stackset/${var.stackset_name}:*"
      },
      {
        Sid = "DLQWrite"
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.dlq.arn
      }
    ]
  })
}

data "archive_file" "reconciler" {
  type        = "zip"
  source_file = "${path.module}/reconciler.py"
  output_path = "${path.module}/reconciler.zip"
}

resource "aws_cloudwatch_log_group" "reconciler" {
  name              = "/aws/lambda/${var.lambda_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "reconciler" {
  function_name    = var.lambda_name
  role             = aws_iam_role.reconciler.arn
  runtime          = "python3.12"
  handler          = "reconciler.lambda_handler"
  timeout          = 600
  memory_size      = 256
  filename         = data.archive_file.reconciler.output_path
  source_code_hash = data.archive_file.reconciler.output_base64sha256

  environment {
    variables = {
      ZS_SECRET_ID     = var.zs_secret_id
      STACKSET_NAME    = aws_cloudformation_stack_set.discovery_role.name
      TARGET_REGION    = var.target_region
      ZTW_REGION_ID    = tostring(var.ztw_region_id)
      ZTW_REGION_NAME  = var.ztw_region_name
      OPT_IN_TAG_KEY   = var.opt_in_tag_key
      OPT_IN_TAG_VALUE = var.opt_in_tag_value
      MANAGED_PREFIX   = var.managed_prefix
      DRY_RUN          = var.dry_run ? "true" : "false"
    }
  }

  dead_letter_config { target_arn = aws_sqs_queue.dlq.arn }

  depends_on = [aws_cloudwatch_log_group.reconciler]
}

# Dead-letter queue for async invocations that error
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.lambda_name}-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# ========== Triggers ==========
resource "aws_cloudwatch_event_rule" "lza_pipeline" {
  name        = "${var.lambda_name}-pipeline-hook"
  description = "Reconcile on ${var.pipeline_name}/${var.stage_name} SUCCEEDED"
  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Stage Execution State Change"]
    detail = {
      pipeline = [var.pipeline_name]
      stage    = [var.stage_name]
      state    = ["SUCCEEDED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline_to_lambda" {
  rule = aws_cloudwatch_event_rule.lza_pipeline.name
  arn  = aws_lambda_function.reconciler.arn
}

resource "aws_lambda_permission" "allow_pipeline_rule" {
  statement_id  = "AllowPipelineRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reconciler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lza_pipeline.arn
}

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${var.lambda_name}-daily"
  description         = "Daily safety-net reconciliation"
  schedule_expression = "rate(24 hours)"
}

resource "aws_cloudwatch_event_target" "daily_to_lambda" {
  rule = aws_cloudwatch_event_rule.daily.name
  arn  = aws_lambda_function.reconciler.arn
}

resource "aws_lambda_permission" "allow_daily" {
  statement_id  = "AllowDailyRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reconciler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}

# ========== Observability ==========
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.lambda_name}-errors"
  alarm_description   = "Reconciler Lambda encountered one or more errors in a 5-minute window"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  dimensions          = { FunctionName = aws_lambda_function.reconciler.function_name }
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "no_invocations_24h" {
  alarm_name          = "${var.lambda_name}-no-invocations-24h"
  alarm_description   = "Reconciler Lambda has not been invoked in 24h — triggers may be misconfigured"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Invocations"
  namespace           = "AWS/Lambda"
  period              = 86400
  statistic           = "Sum"
  threshold           = 1
  dimensions          = { FunctionName = aws_lambda_function.reconciler.function_name }
  treat_missing_data  = "breaching"
}
