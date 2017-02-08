require 'aws-sdk'
require 'dotenv'
require 'json'
require 'memoist'
require 'thor'
require 'byebug'
Dotenv.load

class S3AccountMigration < Thor
  extend Memoist

  desc "list_buckets PROFILE", "list buckets for a given profile"
  def list_buckets(profile)
    puts s3_client(profile: profile).list_buckets.buckets.map(&:name)
  end

  desc 'get_policy BUCKET', "get policy for bucket"
  def get_policy(bucket, profile)
    puts get_bucket_policy(bucket: bucket, profile: profile)
  end

  desc 'migrate_bucket BUCKET SOURCE_PROFILE DESTINATION_PROFILE', 'migrates bucket from source to destination'
  def migrate_bucket(bucket, source_profile, destination_profile)
    raise Exception.new("DESTINATION_ROOT_ID missing from env") if ENV['DESTINATION_ROOT_ID'].nil?
    new_bucket = bucket + ENV['NEW_BUCKET_SUFFIX']

    source_policy = get_bucket_policy(bucket: bucket, profile: source_profile)
    source_policy = remove_s3_delegation_statement(JSON.parse(source_policy))
    updated_source_policy = add_destination_user_statement_to_original_bucket(bucket, deep_copy(source_policy))

    destination_policy = change_bucket_name(policy: source_policy, source_bucket: bucket, destination_bucket: new_bucket)

    begin
      puts "Attempting to create #{new_bucket}"
      s3_client(profile: destination_profile).create_bucket(bucket: new_bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou => e
      puts "You already created and own #{new_bucket}"
    end

    puts "Writing policy from #{bucket} to #{new_bucket}"
    puts destination_policy.to_json
    s3_client(profile: destination_profile).put_bucket_policy(bucket: new_bucket, policy: destination_policy.to_json)

    puts "Adding 'DelegateS3Access' to policy on #{bucket}"
    puts updated_source_policy.to_json
    s3_client(profile: source_profile).put_bucket_policy(bucket: bucket, policy: updated_source_policy.to_json)

    puts "run `aws s3 sync s3://#{bucket} s3://#{new_bucket} --profile #{destination_profile}` to sync the data between buckets"
  end

  no_commands do
    memoize def s3_client(profile:)
      region = Aws.shared_config.fresh(config_enabled: true)[profile]["region"]
      Aws::S3::Client.new(credentials: Aws::SharedCredentials.new(profile_name: profile), region: region)
    end

    def get_bucket_policy(bucket:, profile:)
      begin
        response = s3_client(profile: profile).get_bucket_policy(bucket: bucket).policy.read
      rescue Aws::S3::Errors::NoSuchBucketPolicy => e
        empty_policy
      end
    end

    def change_bucket_name(policy:, source_bucket:, destination_bucket:)
      JSON.parse(policy.to_json.gsub(source_bucket, destination_bucket))
    end

    def deep_copy(o)
      Marshal.load(Marshal.dump(o))
    end

    def empty_policy
      {"Version"=>"2012-10-17","Statement"=>[]}
    end

    def remove_s3_delegation_statement(policy_hash)
      policy_hash["Statement"].reject!{|statement|
        statement["Sid"] == "DelegateS3Access"
      }
      policy_hash
    end

    def add_destination_user_statement_to_original_bucket(bucket, original_policy)
      original_policy["Statement"] << {
          "Sid"=>"DelegateS3Access",
          "Effect"=>"Allow",
          "Principal"=>{
            "AWS"=>"arn:aws:iam::#{ENV['DESTINATION_ROOT_ID']}:root"
          },
          "Action"=>"s3:*",
          "Resource"=>[
            "arn:aws:s3:::#{bucket}/*",
            "arn:aws:s3:::#{bucket}"
            ]
          }
      original_policy
    end
  end
end

S3AccountMigration.start(ARGV)