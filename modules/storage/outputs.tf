output "bucket_name" {
  value = aws_s3_bucket.transcripts.id
}

output "bucket_arn" {
  value = aws_s3_bucket.transcripts.arn
}
