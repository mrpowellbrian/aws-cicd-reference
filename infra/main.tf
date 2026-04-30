locals {
  # Source hash forces a Lambda update whenever handler.py changes,
  # even if no other Terraform resource changes.
  lambda_source_hash = data.archive_file.lambda.output_base64sha256
}

# Package handler.py into a zip for Lambda deployment.
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/handler.py"
  output_path = "${path.module}/../app/handler.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = "aws-cicd-reference API handler"

  filename         = data.archive_file.lambda.output_path
  source_code_hash = local.lambda_source_hash
  handler          = "handler.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_exec.arn

  environment {
    variables = {
      FUNCTION_VERSION = var.function_version
    }
  }

  # checkov:skip=CKV_AWS_116: DLQ not required for a synchronous HTTP-triggered function.
  # checkov:skip=CKV_AWS_117: VPC placement omitted intentionally in this reference; adds
  #   NAT Gateway cost and complexity without benefit for a public API function.
  # checkov:skip=CKV_AWS_272: Code signing omitted; deployment integrity is enforced by
  #   the pipeline (SHA-pinned actions, Checkov, OIDC-scoped deploy role).

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda,
  ]
}
