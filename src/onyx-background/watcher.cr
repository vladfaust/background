require "logger"
require "redis"

# Watches for ready and stale jobs.
#
# In particular:
#
# * Watches scheduled jobs and moves them to the "ready" queue when the time is right
# * Watches a job's worker status, failing the job if the worker is offline
#
# In general, it's recommended to always run a Watcher, even if you don't have scheduled jobs,
# because it also detects stale jobs.
#
# NOTE: There must be only one watcher in the whole application to avoid possible intersection errors.
class Onyx::Background::Watcher
  # :nodoc:
  # Queues to watch. Defaults to `{"default"}`.
  property queues : Enumerable(String)

  # :nodoc:
  # A Redis instance to use. Defaults to `Redis.new`.
  property redis : Redis

  # :nodoc:
  # A Logger instance to use for logging. Defaults to `Logger.new`.
  property logger : Logger

  # :nodoc:
  # The Redis namespace to work in. Defaults to `"onyx-background"`.
  property namespace : String

  # :nodoc:
  # An interval between checks. Defaults to `1.second`.
  property interval : Time::Span
  @interval = 1.second

  # Whether is this worker told to stop (but not necessarily already stopped).
  getter? stopping : Bool = false

  # Whether is this worker currently working.
  getter? running : Bool = false

  # Initialize a new `Watcher`. Call `run` afterwards to run it.
  #
  # ```
  # watcher = Onyx::Background::Watcher.new
  # watcher.run
  # ```
  #
  # NOTE: Currently it's highly recommended to run a single watcher
  # within the whole application to avoid intersection errors.
  #
  # Arguments:
  #
  # * *queues* -- queues to watch
  # * *redis* -- a Redis instance to use
  # * *logger* -- a Logger instance to use for logging
  # * *namespace* -- the Redis namespace to work in
  def initialize(
    @queues : Enumerable(String) = {"default"},
    @redis : Redis = Redis.new,
    @logger : Logger = Logger.new,
    @namespace : String = "onyx-background"
  )
    @redis.pipelined { |pipe| pipe.client_setname("onyx-background-watcher") }
  end

  # Begin watching. Blocks the runtime. Call `#stop` from another fiber to stop it.
  def run
    @running = true
    @logger.info("Watching...")

    loop do
      break if @stopping

      # Check if there are any stale jobs with workers offline
      #

      raw_processing_attempt_uuids = uninitialized Redis::Future
      client_list = uninitialized Redis::Future

      @redis.multi do |multi|
        raw_processing_attempt_uuids = multi.smembers("#{@namespace}:processing")
        client_list = multi.client_list(:normal)
      end

      processing_attempt_uuids = raw_processing_attempt_uuids.value.as(Array).map(&.as(String))

      if processing_attempt_uuids.any?
        # Extract worker fibers only from the client list
        fibers = client_list.value.as(String).split("\n").map do |client|
          client.match(/id=(?<id>\d+).+name=onyx-background-worker-fiber/).try(&.["id"])
        end.compact

        hash = Hash(String, Redis::Future).new

        @redis.multi do |multi|
          processing_attempt_uuids.each do |uuid|
            hash[uuid] = multi.hget("#{@namespace}:attempts:#{uuid}", "wrk")
          end
        end

        stale_attempts = hash.reduce([] of String) do |ary, (uuid, client_id)|
          if client_id.value.nil?
            @logger.warn("[#{uuid}] BUG: Attempt doesn't have \"wrk\"")
            next ary
          end

          unless fibers.includes?(client_id.value.as(String))
            ary << uuid
          end; ary
        end

        if stale_attempts.any?
          @redis.pipelined do |pipe|
            at = Time.now

            stale_attempts.each do |uuid|
              @logger.debug("[#{uuid}] Stale attempt, moving to failed")

              # Update the attempt with error
              pipe.hset("#{@namespace}:attempts:#{uuid}", "err", "Worker Timeout") # Error

              # Remove the attempt from the processing list
              pipe.srem("#{@namespace}:processing", uuid)

              # Add the attempt to the failed list
              pipe.zadd("#{@namespace}:failed", at.to_unix_ms, uuid)
            end
          end
        end
      end

      # Check if there are any scheduled jobs ready to be performed
      #

      @queues.each do |queue|
        ready_jobs = @redis.zrangebyscore("#{@namespace}:queues:scheduled:#{queue}", 0, Time.now.to_unix_ms)

        if ready_jobs.any?
          @redis.multi do |multi|
            ready_jobs.each do |uuid|
              @logger.debug("[#{uuid}] Ready, moving to ready queue")

              multi.zrem("#{@namespace}:queues:scheduled:#{queue}", uuid)
              multi.rpush("#{@namespace}:queues:ready:#{queue}", uuid)
            end
          end
        end
      end

      sleep(interval)
    end

    @logger.info("Stopped")
    @running = false
  end

  # Gracefully stop the watcher. Will wait until the next looping *interval*.
  def stop
    @stopping = true
  end
end
