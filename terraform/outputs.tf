output "lambda_name" {
  description = "Reconciler Lambda function name."
  value       = aws_lambda_function.reconciler.function_name
}

output "lambda_arn" {
  description = "Reconciler Lambda function ARN."
  value       = aws_lambda_function.reconciler.arn
}

output "stackset_name" {
  description = "Discovery-role CloudFormation StackSet name."
  value       = aws_cloudformation_stack_set.discovery_role.name
}

output "pipeline_rule_arn" {
  description = "EventBridge rule that fires on LZA pipeline stage SUCCEEDED."
  value       = aws_cloudwatch_event_rule.lza_pipeline.arn
}

output "daily_rule_arn" {
  description = "EventBridge rule for daily safety-net reconciliation."
  value       = aws_cloudwatch_event_rule.daily.arn
}

output "dlq_url" {
  description = "Dead-letter queue URL for failed Lambda invocations."
  value       = aws_sqs_queue.dlq.url
}

output "log_group_name" {
  description = "CloudWatch Logs group for the reconciler."
  value       = aws_cloudwatch_log_group.reconciler.name
}
