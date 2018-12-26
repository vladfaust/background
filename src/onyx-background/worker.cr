require "logger"
require "redis"
require "uuid"

require "./errors/job_not_found_by_uuid"
require "./ext/redis/commands"
require "./worker/redis_pool"

# Actually performs jobs.
class Onyx::Background::Worker
  # :nodoc:
  # The job queues this worker will work on. Defaults to `{"default"}`.
  property queues : Enumerable(String)

  # :nodoc:
  # The maximum amount of fibers. Each fiber spawns a Redis client. Defaults to `100`.
  property fibers : Int32

  # :nodoc:
  # A proc to initialize a new Redis client. Defaults to `->{ Redis.new }`.
  property redis_proc : Proc(Redis)

  # :nodoc:
  # A Logger instance for this worker. Defaults to `Logger.new(STDOUT)`.
  property logger : Logger

  # :nodoc:
  # The namespace this worker and its fibers will work in. Defaults to `"onyx-background"`.
  property namespace : String

  # :nodoc:
  # The main Redis client. Set in `#initialize`.
  getter redis : Redis

  # :nodoc:
  # The main Redis client ID. Set in `#initialize`
  getter redis_client_id : Int64

  # Whether is this worker told to stop (but not necessarily already stopped).
  getter? stopping : Bool = false

  # Whether is this worker currently working.
  getter? running : Bool = false

  # Initialize a new `Worker`. Call `run` afterwards to run it.
  #
  # ```
  # worker = Onyx::Background::Worker.new
  # worker.run
  # ```
  #
  # Arguments:
  #
  # * *queues* -- the job queues this worker will work on
  # * *fibers* -- the maximum amount of fibers. Each fiber spawns a Redis client
  # * *redis_proc* -- a proc to initialize a new Redis client
  # * *logger* -- a Logger instance for this worker
  # * *namespace* -- the namespace this worker and its fibers will work in
  def initialize(
    @queues : Enumerable(String) = {"default"},
    @fibers : Int32 = 100,
    @redis_proc : Proc(Redis) = ->{ Redis.new },
    @logger : Logger = Logger.new(STDOUT),
    @namespace : String = "onyx-background"
  )
    @redis = @redis_proc.call
    redis_client_id, _ = @redis.multi do |multi|
      multi.client_id
      multi.client_setname("onyx-background-worker:#{@queues.join(',')}")
    end

    @redis_client_id = redis_client_id.as(Int64)
  end

  # Begin working. Blocks the runtime.
  def run
    # TODO: Make re-run possible
    raise "Cannot re-run a stopped worker" if @stopping

    @running = true
    logger.info("Working...")

    # Cleanup unused redis clients
    # TODO: Stop cleanups if the worker is stopped
    spawn do
      loop do
        redis_pool_cleanup
        sleep 1
      end
    end

    keys = @queues.to_a.map { |q| "#{@namespace}:ready:#{q}" }

    loop do
      break if @stopping

      client, client_id = redis_pool_get(@redis_client_id)
      @logger.debug("Waiting for a new job...")

      queue, job_uuid = begin
        @redis.blpop(keys, 0).not_nil!
      rescue ex : Redis::Error
        # If the connection is UNBLOCKED, then it's intended
        # (presumably caused by `#stop`)
        break if ex.message =~ /^UNBLOCKED/

        # Otherwise raise
        raise ex
      end

      queue = queue.as(String).match(/#{@namespace}:ready:(\w+)/).not_nil![1]

      spawn process_job(client, client_id, queue, job_uuid.as(String))
    end

    @running = false
    logger.info("Stopped")
  end

  # Stop this worker.
  # It needs a separate Redis connection to unblock the worker's client remotely.
  # Always closes the main `#redis` connection (but not `ensure`d).
  #
  # * If *fibers_force_kill* is `true`, will force close all underlying fibers' connections,
  # active jobs will fail with Redis error
  # * If *fibers_force_kill* is `false` and *fibers_timeout* is not `nil`,
  # will wait for *fibers_timeout* until all fibers are completed,
  # and force close all fibers if it takes longer time
  # * If *fibers_force_kill* is `false` and *fibers_timeout* is `nil`,
  # will not wait for fibers to complete, just close the main connection
  def stop(
    redis : Redis = Redis.new,
    fibers_force_kill : Bool = false,
    fibers_timeout fibers_timeout? : Time::Span? = 1.second,
    fibers_check_interval : Time::Span = 1.millisecond
  )
    raise "Worker already stopped" if @stopping
    raise "Worker needs to be running to stop" unless @running

    @stopping = true
    redis.client_unblock(@redis_client_id, true)

    if fibers_force_kill
      redis_pool_clear(@redis)
    elsif fibers_timeout = fibers_timeout?
      started_at = Time.monotonic

      # Wait until there are no fibers using a redis connection from the pool.
      # If it takes longer than *fibers_timeout*,
      # force clear the pool (active jobs will fail with Redis errors).
      loop do
        if @redis_pool_is_using.values.any?(&.itself)
          if Time.monotonic - started_at > fibers_timeout
            redis_pool_clear(@redis)
            break
          end
        else
          break
        end

        sleep(fibers_check_interval)
      end
    end

    @redis.close
  end

  # Attempt to process a `Job` by its *job_uuid*.
  protected def process_job(client : Redis, client_id : Int64, queue : String, job_uuid : String)
    @logger.debug("[#{job_uuid}] Attempting")
    started_at = Time.monotonic

    begin
      job = client.fetch_hash("#{@namespace}:jobs:#{job_uuid}", "cls", "arg")
      raise Errors::JobNotFoundByUUID.new(job_uuid) unless job.any?

      attempt_uuid = UUID.random.to_s
      job["uuid"] = job_uuid
      return unless create_attempt?(client, client_id, attempt_uuid, queue, job)

      klass = self.class.job_class(job["cls"].as(String))
      instance = klass.from_json(job["arg"].as(String))
      instance.attempt_uuid = attempt_uuid

      @logger.debug("[#{attempt_uuid}] Performing #{klass} #{job["arg"]}...")
      instance.perform
      @logger.debug("[#{attempt_uuid}] Completed")

      client.pipelined do |pipe|
        at = Time.now

        # Update the attempt with finished at time and processing time
        pipe.hmset("#{@namespace}:attempts:#{attempt_uuid}", {
          "fin" => at.to_unix_ms,                                    # Finished at
          "tim" => (Time.monotonic - started_at).total_milliseconds, # Processing time
        })

        # Remove the attempt from the processing list
        pipe.srem("#{@namespace}:processing:#{queue}", attempt_uuid)

        # Add the attempt to the completed list
        pipe.zadd("#{@namespace}:completed:#{queue}", at.to_unix_ms, attempt_uuid)
      end
    rescue ex : Errors::JobNotFoundByUUID
      @logger.error("[#{attempt_uuid}] Job not found by UUID")
    rescue ex : Exception
      @logger.warn("[#{attempt_uuid}] Job error: " + ex.inspect_with_backtrace)

      if attempt_uuid
        client.pipelined do |pipe|
          at = Time.now

          # Update the attempt with finished at time, processing time and the error name
          pipe.hmset("#{@namespace}:attempts:#{attempt_uuid}", {
            "fin" => at.to_unix_ms,                                    # Finished at
            "tim" => (Time.monotonic - started_at).total_milliseconds, # Processing time
            "err" => ex.class.name,                                    # Error
          })

          # Remove the attempt from the processing list
          pipe.srem("#{@namespace}:processing:#{queue}", attempt_uuid)

          # Add the attempt to the failed list
          pipe.zadd("#{@namespace}:failed:#{queue}", at.to_unix_ms, attempt_uuid)
        end
      end
    ensure
      redis_pool_return(client)
    end
  end

  protected def create_attempt?(
    client : Redis,
    client_id : Int64,
    attempt_uuid : String,
    queue : String,
    job : Hash
  ) : Bool
    client.pipelined do |pipe|
      pipe.sadd("#{@namespace}:processing:#{queue}", attempt_uuid)
      pipe.hmset("#{@namespace}:attempts:#{attempt_uuid}", {
        "sta" => Time.now.to_unix_ms, # Started at
        "job" => job["uuid"],         # Job UUID
        "wrk" => client_id,           # Worker fiber Redis client ID
        "que" => queue,               # Actual queue
      })
    end

    return true
  end

  # Get a Job class *from* a string. Will be expanded with every `Onyx::Job` inclusion.
  protected def self.job_class(from : String)
    raise JobNotFoundByClass.new(from)
  end

  private class JobNotFoundByClass < Exception
    getter class_string : String

    def initialize(@class_string)
      super("Job not found by class #{@class_string}")
    end
  end
end
