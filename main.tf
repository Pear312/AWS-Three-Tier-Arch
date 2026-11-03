provider "aws" {
  region = var.region
}

///////////////////////
//                   //
// Presentation Tier //
//                   //
///////////////////////
locals {
  s3_origin_id = "myS3Origin"

  content_types = {
    html = "text/html"
    css  = "text/css"
    js   = "application/javascript"
  }
}

// Create an s3 bucket
resource "aws_s3_bucket" "this" {
  bucket = "emai-three-tier-bucket"
  force_destroy = true

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

// Adds all website files into s3 bucket
resource "aws_s3_object" "website_files" {
  for_each = fileset("${path.module}/website", "*")

  bucket = aws_s3_bucket.this.id
  key    = each.value
  source = "${path.module}/website/${each.value}"
  etag         = filemd5("${path.module}/website/${each.value}")
  content_type = lookup(
    local.content_types,
    element(reverse(split(".", each.value)), 0),
    "application/octet-stream"
  )
}

// Bucket Policy
resource "aws_s3_bucket_policy" "AllowReadWrite" {
  bucket = aws_s3_bucket.this.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",

      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },

      "Action": [
        "s3:GetObject"
      ],

      "Resource": [
        "${aws_s3_bucket.this.arn}/*"
      ],

      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "${aws_cloudfront_distribution.s3_distribution.arn}"
        }
      }
    }
  ] 
}
EOF
}


// CloudFront Distribution
resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "default-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
    origin_id                = local.s3_origin_id
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 10
    max_ttl                = 20
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US"]
    }
  }

  tags = {
    Environment = "Dev"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

////////////////
//            //
// Logic Tier //
//            //
////////////////

// Retrieve data from database
resource "aws_iam_role" "retrieve_from_database" {
  name = "lambda_access_to_database"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Sid" : "",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      }
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "dynamodb_read_policy" {
  name = "dynamodb_read_access"
  role = aws_iam_role.retrieve_from_database.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:DescribeTable"
      ],
      "Resource": "${aws_dynamodb_table.userData.arn}"
    }
  ] 
}
EOF
}


data "archive_file" "retrieveUserData_zip" {
  type        = "zip"
  source_file = "${path.module}/logic/retrieveUserData.mjs" 
  output_path = "${path.module}/retrieveUserData_function.zip"
}

resource "aws_lambda_function" "RetrieveUserDatabase" {
  filename = "${path.module}/retrieveUserData_function.zip"
  function_name = "DatabaseRetrieve_terraform_lambda"
  role = aws_iam_role.retrieve_from_database.arn

  source_code_hash = data.archive_file.retrieveUserData_zip.output_base64sha256
  
  runtime          = "nodejs20.x"
  handler          = "retrieveUserData.handler"
}


// API Gateway
resource "aws_api_gateway_rest_api" "api" {
  name = "UserRequestAPI"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_method" "get_users" {
  authorization = "NONE"
  http_method   = "GET"
  resource_id   = aws_api_gateway_resource.users.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
}

resource "aws_api_gateway_integration" "lambda" {
  http_method = aws_api_gateway_method.get_users.http_method
  resource_id = aws_api_gateway_resource.users.id
  rest_api_id = aws_api_gateway_rest_api.api.id
  
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.RetrieveUserDatabase.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.RetrieveUserDatabase.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}


resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.users,
      aws_api_gateway_method.get_users,
      aws_api_gateway_integration.lambda,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "dev"
}

output "api_url" {
  value = "${aws_api_gateway_stage.dev.invoke_url}/users"
}


///////////////
//           //
// Data Tier //
//           //
///////////////

// Dynamodb database
resource "aws_dynamodb_table" "userData" {
  name = "UserData"
  hash_key = "userId"
  read_capacity  = 10
  write_capacity = 10

  attribute {
    name = "userId"
    type = "S"
  }

  tags = {
    Name        = "dynamodb-table-userData"
    Environment = "dev"
  }
}

resource "aws_dynamodb_table_item" "userExample" {
  table_name = aws_dynamodb_table.userData.name
  hash_key   = aws_dynamodb_table.userData.hash_key

  item = <<ITEM
{
  "userId": {"S": "1"},
  "name":   {"S": "Test User"},
  "email":  {"S": "test@example.com"}
}
ITEM
}




