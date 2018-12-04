require "spec"
require "../src/onyx-background"

raise "REDIS_URL environment variable is not set" unless ENV["REDIS_URL"]?

def namespace
  "onyx-background-spec"
end

def redis
  Redis.new(url: ENV["REDIS_URL"])
end

redis.flushdb
