######################################################
# Variables
######################################################

terraform {
  backend "s3" {
    bucket                  = ""
    key                     = ""
    region                  = ""
    profile                 = ""
    shared_credentials_file = ""
  }
}

data "aws_caller_identity" "current" {}

provider "aws" {
  region                  = "${var.aws_region}"
  shared_credentials_file = ""
  profile                 = ""
}

provider "aws" {
  alias                   = "us"
  region                  = "us-east-1"
  shared_credentials_file = ""
  profile                 = ""
}

data "aws_acm_certificate" "main_cert" {
  provider = "aws.us"
  domain   = "${var.default_domain}"

  statuses = [
    "ISSUED",
  ]
}

######################################################
# S3 buckets
######################################################

##############
# admin
##############

locals {
  bucket_name_b = "${var.project}-${var.name}-${var.stage}"
}

resource "aws_s3_bucket" "b" {
  bucket = "${lower(local.bucket_name_b)}"
  acl    = "private"

  tags {
    Name    = "${lower(local.bucket_name_b)}"
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "admin"
  }
}

locals {
  bucket_name_x = "${var.project}-${var.name}-www-redirect-${var.stage}"
}

resource "aws_s3_bucket" "x" {
  bucket = "${lower(local.bucket_name_x)}"
  acl    = "private"

  website {
    redirect_all_requests_to = "https://${var.default_domain}"
  }

  tags {
    Name    = "${lower(local.bucket_name_x)}"
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "www-redirect"
  }
}

######################################################
# CloudFront distributions
######################################################

##############
# OAI
##############

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  provider = "aws.us"
  comment  = "CloudFront Origin Access"
}

data "aws_iam_policy_document" "s3_policy_b" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.b.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.b.arn}"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }
}

resource "aws_s3_bucket_policy" "origin-access-admin" {
  bucket = "${aws_s3_bucket.b.id}"
  policy = "${data.aws_iam_policy_document.s3_policy_b.json}"
}

##############
# variables
##############

locals {
  s3_origin_id__admin        = "${lower(var.name)}-${lower(var.stage)}"
  s3_origin_id__www-redirect = "${lower(var.name)}-www-redirect-${lower(var.stage)}"
}

##############
# admin
##############

resource "aws_cloudfront_distribution" "s3_distribution__admin" {
  provider = "aws.us"

  origin {
    domain_name = "${aws_s3_bucket.b.bucket_regional_domain_name}"
    origin_id   = "${local.s3_origin_id__admin}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
    }
  }

  price_class         = "PriceClass_100"
  comment             = "${var.project}-${var.name}-${var.stage}"
  enabled             = true
  is_ipv6_enabled     = false
  default_root_object = "index.html"

  aliases = ["${var.default_domain}"]

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id__admin}"
    compress         = true

    min_ttl     = 0
    max_ttl     = 31536000
    default_ttl = 31536000

    forwarded_values {
      query_string = true

      cookies {
        forward = "none"
      }
    }

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = "${aws_lambda_function.lambda.qualified_arn}"
      include_body = false
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  tags {
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "admin"
  }

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.main_cert.arn}"
    ssl_support_method  = "sni-only"
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    error_caching_min_ttl = 0
    response_page_path    = "/index.html"
  }
}

##############
# www-redirect
##############

resource "aws_cloudfront_distribution" "s3_distribution__www-redirect" {
  provider = "aws.us"

  origin {
    domain_name = "${local.bucket_name_x}.s3-website.${var.aws_region}.amazonaws.com"
    origin_id   = "${local.s3_origin_id__www-redirect}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  price_class     = "PriceClass_100"
  comment         = "${var.project}-${var.name}-www-redirect-${var.stage}"
  enabled         = true
  is_ipv6_enabled = false

  aliases = ["www.${var.default_domain}"]

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id__www-redirect}"
    compress         = true

    min_ttl     = 31536000
    max_ttl     = 31536000
    default_ttl = 31536000

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
  }

  tags {
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "www-redirect"
  }

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.main_cert.arn}"
    ssl_support_method  = "sni-only"
  }
}

######################################################
# Lambda
######################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com", "s3.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_access" {
  statement {
    effect  = "Allow"
    actions = ["s3:*"]

    resources = ["arn:aws:s3:::${aws_s3_bucket.b.bucket}", "arn:aws:s3:::${aws_s3_bucket.b.bucket}/*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "${lower(var.name)}-${lower(var.stage)}-lambda-role-passwd"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role.json}"
}

resource "aws_iam_role" "iam_for_lambda_try_files" {
  name               = "${lower(var.name)}-${lower(var.stage)}-lambda-role-try-files"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role.json}"
}

resource "aws_iam_role" "iam_for_lambda_trailing_slash" {
  name               = "${lower(var.name)}-${lower(var.stage)}-lambda-role-trailing-slash"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role.json}"
}

resource "aws_iam_role_policy" "lambda-access" {
  name   = "lambda_access"
  role   = "${aws_iam_role.iam_for_lambda_try_files.id}"
  policy = "${data.aws_iam_policy_document.lambda_access.json}"
}

# basic_auth

resource "aws_lambda_function" "lambda" {
  provider         = "aws.us"
  filename         = "lambda-basic-auth/lambda-basic-auth.zip"
  function_name    = "${lower(var.name)}-${lower(var.stage)}-passwd"
  role             = "${aws_iam_role.iam_for_lambda.arn}"
  handler          = "index.handler"
  source_code_hash = "${base64sha256(file("lambda-basic-auth/lambda-basic-auth.zip"))}"
  runtime          = "nodejs8.10"
  publish          = true
  timeout          = 5
  memory_size      = 128

  tags {
    Name    = "${lower(var.name)}-${lower(var.stage)}-basic-auth"
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "lambda-basic-auth"
  }
}

# try_files

resource "aws_lambda_function" "lambda_try_files" {
  provider         = "aws.us"
  filename         = "lambda-try-files/lambda-try-files.zip"
  function_name    = "${lower(var.name)}-${lower(var.stage)}-try-files"
  role             = "${aws_iam_role.iam_for_lambda_try_files.arn}"
  handler          = "index.handler"
  source_code_hash = "${base64sha256(file("lambda-try-files/lambda-try-files.zip"))}"
  runtime          = "nodejs8.10"
  publish          = true
  timeout          = 5
  memory_size      = 128
  depends_on       = ["aws_s3_bucket.b"]

  tags {
    Name    = "${lower(var.name)}-${lower(var.stage)}-try-files"
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "lambda-try-files"
  }
}

# trailing_slash

resource "aws_lambda_function" "lambda_trailing_slash" {
  provider         = "aws.us"
  filename         = "lambda-trailing-slash/lambda-trailing-slash.zip"
  function_name    = "${lower(var.name)}-${lower(var.stage)}-trailing-slash"
  role             = "${aws_iam_role.iam_for_lambda_trailing_slash.arn}"
  handler          = "index.handler"
  source_code_hash = "${base64sha256(file("lambda-trailing-slash/lambda-trailing-slash.zip"))}"
  runtime          = "nodejs8.10"
  publish          = true
  timeout          = 5
  memory_size      = 128

  tags {
    Name    = "${lower(var.name)}-${lower(var.stage)}-trailing-slash"
    Project = "${var.proj-tag}"
    Stage   = "${var.stage}"
    App     = "lambda-trailing-slash"
  }
}

######################################################
# User
######################################################

resource "aws_iam_user" "circle" {
  name = "${var.name}-${var.stage}-fe"
}

resource "aws_iam_access_key" "circle" {
  user = "${aws_iam_user.circle.name}"
}

data "aws_iam_policy_document" "policy_for_circleci" {
  statement {
    effect  = "Allow"
    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::${aws_s3_bucket.b.bucket}",
      "arn:aws:s3:::${aws_s3_bucket.b.bucket}/*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["cloudfront:CreateInvalidation"]

    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "lb_ro" {
  user   = "${aws_iam_user.circle.name}"
  policy = "${data.aws_iam_policy_document.policy_for_circleci.json}"
}

######################################################
# Outputs
######################################################

# main 

output "AWS_DEFAULT_REGION" {
  value = "${var.aws_region}"
}

output "AWS_ACCOUNT_ID" {
  value = "${data.aws_caller_identity.current.account_id}"
}

output "AWS_S3_BUCKET_ADMIN" {
  value = "s3://${local.bucket_name_b}"
}

output "AWS_ACCESS_KEY_ID" {
  value = "${aws_iam_access_key.circle.id}"
}

output "AWS_SECRET_ACCESS_KEY" {
  value = "${aws_iam_access_key.circle.secret}"
}

output "AWS_CLOUDFRONT_DISTIRBUTION_ID_ADMIN" {
  value = "${aws_cloudfront_distribution.s3_distribution__admin.id}"
}

output "x-default_domain" {
  value = "https://${var.default_domain}"
}
