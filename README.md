# AWS S3 account migration

## What is this
This is an attempt to automate the migration of buckets and their policies from one AWS S3 account to another.
This is a work in progress.

## Config
Uses shared configuration settings store `~/.aws/config` and `~/.aws/credentials`

Source profile needs policy and read access to the source s3 account.
The script adds a policy to buckets to allow the destination account to delegate access to the destination profile.

Destination profile is an iam user on the destination account that has full access to s3:
`{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": "*"
        }
    ]
}`

This allows the same user to be used for syncing files accross.

There is no support. Use at your own risk