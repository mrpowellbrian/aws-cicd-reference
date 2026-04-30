output "api_endpoint" {
  description = "Base URL of the deployed API Gateway endpoint."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed Lambda function."
  value       = aws_lambda_function.this.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for the Lambda function."
  value       = aws_cloudwatch_log_group.lambda.name
}
