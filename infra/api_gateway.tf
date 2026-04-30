# HTTP API (API Gateway v2) — lower cost and latency than REST API for
# Lambda proxy integrations. Lacks some REST API features (usage plans,
# API keys, custom authorizers via Lambda — though JWT authorizers are
# supported). Appropriate for this reference.

resource "aws_apigatewayv2_api" "this" {
  name          = var.function_name
  protocol_type = "HTTP"
  description   = "aws-cicd-reference HTTP API"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.this.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "catch_all" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  # Scope to this API only — not all API Gateways in the account.
  source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
