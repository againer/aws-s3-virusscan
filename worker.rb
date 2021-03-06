#!/usr/bin/env ruby

require 'aws-sdk'
require 'json'
require 'uri'
require 'yaml'
require 'syslog/logger'

log = Syslog::Logger.new 's3-virusscan'
conf = YAML.load_file(__dir__ + '/s3-virusscan.conf')

Aws.config.update(region: conf['region'])
s3 = Aws::S3::Client.new
sns = Aws::SNS::Client.new

poller = Aws::SQS::QueuePoller.new(conf['queue'])

log.info('s3-virusscan started')

poller.poll do |msg|
  body = JSON.parse(msg.body)
  next unless body.key?('Records')

  # Scan each record available.
  body['Records'].each do |record|
    # Set bucket and key for getting a bucket item.
    bucket = record['s3']['bucket']['name']
    key = URI.decode(record['s3']['object']['key']).tr('+', ' ')

    log.debug "scanning s3://#{bucket}/#{key}..."

    # Ensure scannable object exists.
    begin
      s3.get_object(response_target: '/tmp/target', bucket: bucket, key: key)
    rescue Aws::S3::Errors::NoSuchKey
      log.debug "s3://#{bucket}/#{key} no longer exists. Skipping..."
      next
    end

    # Scan the target and check the result's exit status.
    system('clamscan --max-filesize=100M --max-scansize=500M /tmp/target')
    result = $CHILD_STATUS.exitstatus
    log.debug "clamscan exit code = #{result}"

    if result.zero?
      log.debug "s3://#{bucket}/#{key} was scanned without findings"
    elsif result == 2
      log.debug "ClamAV had an issue and did not scan the file. Skipped #{key}"
    elsif result == 1
      if conf['delete']
        log.error "s3://#{bucket}/#{key} is infected, deleting..."
        sns.publish(
          topic_arn: conf['topic'],
          message: "s3://#{bucket}/#{key} is infected, deleting...",
          subject: "s3-virusscan s3://#{bucket}",
          message_attributes: {
            'key' => {
              data_type: 'String',
              string_value: "s3://#{bucket}/#{key}"
            }
          }
        )
        begin
          s3.delete_object(
            bucket: bucket,
            key: key
          )
          log.error "s3://#{bucket}/#{key} was deleted"
        rescue StandardError => ex
          log.error("Caught #{ex.class} error calling delete_object on #{key}.")
        end
      else
        log.error "s3://#{bucket}/#{key} is infected"
        sns.publish(
          topic_arn: conf['topic'],
          message: "s3://#{bucket}/#{key} is infected",
          subject: "s3-virusscan s3://#{bucket}",
          message_attributes: {
            'key' => {
              data_type: 'String',
              string_value: "s3://#{bucket}/#{key}"
            }
          }
        )
      end
    end
    system('rm /tmp/target')
  end
end
