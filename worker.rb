#!/usr/bin/env ruby

require 'aws-sdk'
require 'English'
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

log.info 's3-virusscan started'

poller.poll do |msg|
  body = JSON.parse(msg.body)
  if body.key?('Records')
    body['Records'].each do |record|
      bucket = record['s3']['bucket']['name']
      key = URI.decode(record['s3']['object']['key']).tr('+', ' ')
      log.debug "scanning s3://#{bucket}/#{key}..."
      begin
        s3.get_object(response_target: '/tmp/target', bucket: bucket, key: key)
      rescue Aws::S3::Errors::NoSuchKey
        log.debug "s3://#{bucket}/#{key} does no longer exist"
        next
      end
      if system('clamscan /tmp/target')
        log.debug "s3://#{bucket}/#{key} was scanned without findings"
      end
      message = "s3://#{bucket}/#{key} is infected"
      message = "s3://#{bucket}/#{key} is infected, deleting." if conf['delete']
      log.error(message)

      # Delete the asset.
      if conf['delete']
        s3.delete_object(bucket: bucket, key: key)
        log.error("s3://#{bucket}/#{key} was deleted")
      end

      # Publish to the SNS topic.
      sns.publish(
        topic_arn: conf['topic'],
        message: message,
        subject: "s3-virusscan s3://#{bucket}",
        message_attributes: {
          'key' => {
            data_type: 'String',
            string_value: "s3://#{bucket}/#{key}"
          }
        }
      )
      system('rm /tmp/target')
    end
  end
end
