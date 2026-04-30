variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name. Used in resource tags."
  type        = string
  default     = "production"
}

variable "function_name" {
  description = "Name of the Lambda function."
  type        = string
  default     = "aws-cicd-reference-api"
}

variable "function_version" {
  description = "Version string injected by CI at deploy time (e.g. git SHA)."
  type        = string
  default     = "local"
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by the CloudWatch Logs API."
  }
}
