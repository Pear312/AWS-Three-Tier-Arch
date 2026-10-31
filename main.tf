provider "aws" {
  region = var.region
}

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

