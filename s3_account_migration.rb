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

  desc 'get_website BUCKET', "get website for bucket"
  def get_website(bucket, profile)
    puts get_bucket_website(bucket: bucket, profile: profile)
  end

  desc 'rename_bucket BUCKET PROFILE', 'rename bucket on same account'
  def rename_bucket(bucket, profile)
    source_bucket = bucket + ENV['SOURCE_BUCKET_SUFFIX']
    destination_bucket = bucket

    source_policy = get_bucket_policy(bucket: source_bucket, profile: profile)

    create_bucket(bucket: destination_bucket, profile: profile)
    # copy_policy(source_bucket: source_bucket, destination_bucket: destination_bucket, profile: profile)

  end

  desc 'migrate_bucket BUCKET SOURCE_PROFILE DESTINATION_PROFILE', 'migrates bucket from source to destination'
  def migrate_bucket(source_bucket, source_profile, destination_profile)
    raise Exception.new("DESTINATION_ROOT_ID missing from env") if ENV['DESTINATION_ROOT_ID'].nil?
    destination_bucket = source_bucket + ENV['DESTINATION_BUCKET_SUFFIX']

    source_policy = get_bucket_policy(bucket: source_bucket, profile: source_profile)
    source_policy = remove_s3_delegation_statement(JSON.parse(source_policy))
    destination_policy = change_bucket_name(policy: source_policy, source_bucket: source_bucket, destination_bucket: destination_bucket)

    create_bucket(bucket: destination_bucket, profile: destination_profile)

    # if source_policy.nil? || source_policy["Statement"].empty?
    #   puts "Source policy from #{source_bucket} was nil. Nothing to write to destination #{destination_bucket}"
    # else
    #   puts "Writing policy from #{source_bucket} to #{destination_bucket}"
    #   s3_client(profile: destination_profile).put_bucket_policy(bucket: destination_bucket, policy: destination_policy.to_json)
    # end
    puts "Writing policy from #{source_bucket} to #{destination_bucket}"
    put_bucket_policy(bucket: destination_bucket, profile: destination_profile, policy: destination_policy)

    puts "Adding 'DelegateS3Access' to policy on #{source_bucket}"
    updated_source_policy = add_destination_user_statement_to_original_bucket(bucket: source_bucket, original_policy: source_policy)
    put_bucket_policy(bucket: source_bucket, policy: updated_source_policy, profile: source_profile)

    source_website = get_bucket_website(bucket: source_bucket, profile: source_profile)

    if source_website.nil?
      puts "No website settings to transfer"
    else
      puts "Writing website settings to #{destination_bucket}"
      destination_website = website_put_from_response(destination_bucket: destination_bucket, source_data: source_website)
      puts destination_website
      s3_client(profile: destination_profile).put_bucket_website(destination_website)
    end

    puts "run `aws s3 sync s3://#{source_bucket} s3://#{destination_bucket} --profile #{destination_profile}` to sync the data between buckets"
  end

  no_commands do
    memoize def s3_client(profile:)
      region = Aws.shared_config.fresh(config_enabled: true)[profile]["region"]
      Aws::S3::Client.new(credentials: Aws::SharedCredentials.new(profile_name: profile), region: region)
    end

    def create_bucket(bucket:, profile:)
      begin
        puts "Attempting to create #{bucket}"
        puts
        s3_client(profile: profile).create_bucket(bucket: bucket)
      rescue Aws::S3::Errors::BucketAlreadyOwnedByYou => e
        puts "You already created and own #{bucket}"
      rescue Aws::S3::Errors::BucketAlreadyExists => e
        puts "This bucket already exists. If you're renaming back to the original name but on the new account, make sure it's deleted on the original"
        puts "Verify that all the data and settings you need have transferred properly"
        puts
      rescue Aws::S3::Errors::OperationAborted => e
        puts e.message
        puts "If the bucket name was recently deleted, it can take some time to release it for recreation"
        puts
      end
    end

    def copy_policy(source_bucket:, destination_bucket:, profile:, same_account: true)
      source_policy = get_bucket_policy(bucket: source_bucket, profile: profile)


    end

    def put_bucket_policy(bucket:, policy:, profile:)
      if policy.nil? || policy["Statement"].empty?
        puts "Policy was nil. Nothing to write to #{bucket}"
      else
        puts "Writing policy to #{bucket}"
        s3_client(profile: profile).put_bucket_policy(bucket: bucket, policy: policy.to_json)
      end
    end

    def get_bucket_policy(bucket:, profile:)
      begin
        response = s3_client(profile: profile).get_bucket_policy(bucket: bucket).policy.read
      rescue Aws::S3::Errors::NoSuchBucketPolicy => e
        empty_policy
      end
    end

    def get_bucket_website(bucket:, profile:)
      begin
        response = s3_client(profile: profile).get_bucket_website(bucket: bucket).data

      rescue Aws::S3::Errors::NoSuchWebsiteConfiguration => e
        nil
      end
    end

    def website_put_from_response(destination_bucket:, source_data:)
      {
        bucket: destination_bucket, # required
        website_configuration: {
          error_document: {
            key: source_data&.error_document&.key, # required
          },
          index_document: {
            suffix: source_data&.index_document&.suffix, # required
          },
          redirect_all_requests_to: {
            host_name: source_data&.redirect_all_requests_to&.host_name, # required
            protocol: source_data&.redirect_all_requests_to&.protocol, # accepts http, https
          },
          routing_rules: source_data.routing_rules.map do |rule|
            {
              condition: {
                http_error_code_returned_equals: rule&.http_error_code_returned_equals,
                key_prefix_equals: rule&.key_prefix_equals,
              },
              redirect: { # required
                host_name: rule&.redirect&.host_name,
                http_redirect_code: rule&.redirect&.http_redirect_code,
                protocol: rule&.redirect&.protocol, # accepts http, https
                replace_key_prefix_with: rule&.redirect&.replace_key_prefix_with,
                replace_key_with: rule&.redirect&.replace_key_with,
              },
            }
          end,
        }
      }.compact(recurse: true, delete_empty: true)
    end

    def change_bucket_name(policy:, source_bucket:, destination_bucket:)
      JSON.parse(policy.to_json.gsub(source_bucket, destination_bucket))
    end

    def deep_copy(o)
      Marshal.load(Marshal.dump(o))
    end

    def empty_policy
      {"Version"=>"2012-10-17","Statement"=>[]}.to_json
    end

    def remove_s3_delegation_statement(policy_hash)
      policy_hash["Statement"].reject!{|statement|
        statement["Sid"] == "DelegateS3Access"
      }
      policy_hash
    end

    def add_destination_user_statement_to_original_bucket(bucket: , original_policy: )
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

class Hash
  def compact(**opts)
    inject({}) do |new_hash, (k,v)|
      if !v.nil?
        new_hash[k] = opts[:recurse] && v.class == Hash ? v.compact(opts) : v
      end
      if opts[:delete_empty]
        new_hash.delete_if{|k,v| v.empty?}
      else
        new_hash
      end
    end
  end
end

S3AccountMigration.start(ARGV)