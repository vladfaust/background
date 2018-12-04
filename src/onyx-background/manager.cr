require "./job"

# The background processing manager.
#
# It's intended for use within an application to enqueue and dequeue jobs.
#
# Apart from a standard `Redis` instance, the Manager supports
# [`Redis::TransactionApi`](http://stefanwille.github.io/crystal-redis/Redis/TransactionApi.html)
# and [`Redis::PipelineApi`](http://stefanwille.github.io/crystal-redis/Redis/PipelineApi.html),
# which allows to use it in a `multi` or `pipelined` block:
#
# ```
# redis.pipelined do |pipe|
#   manager = Onyx::Background::Manager.new(pipe)
#
#   100.times do
#     manager.enqueue(MyJob) # All 100 enqueues will happen in one pipe, which is much faster
#   end
# end
# ```
class Onyx::Background::Manager
  # :nodoc:
  # A Redis instance to use. Defaults to `Redis.new`.
  property redis : Redis | Redis::TransactionApi | Redis::PipelineApi

  # :nodoc:
  # A Redis namespace to work in. Defaults to `"onyx-background"`.
  property namespace : String

  # Initialize a new `Manager`.
  #
  # Arguments:
  #
  # * *redis* -- a Redis instance to use
  # * *namespace* -- a Redis namespace to work in
  def initialize(
    @redis : Redis | Redis::TransactionApi | Redis::PipelineApi = Redis.new,
    @namespace : String = "onyx-background"
  )
    case @redis
    when Redis
      @redis.as(Redis).pipelined { |pipe| pipe.client_setname("onyx-background-manager") }
    else
      @redis.client_setname("onyx-background-manager")
    end
  end

  # Enqueue a *job* instance. See [`#enqueue`](#enqueue%28classklass%3AString%2Cpayload%3AString%3D%26quot%3B%7B%7D%26quot%3B%2C%2A%2Cqueue%3AString%3D%26quot%3Bdefault%26quot%3B%2Cin%3ATime%3A%3ASpan%3F%3Dnil%2Cat%3ATime%3F%3Dnil%29-instance-method) for options.
  #
  # Example:
  #
  # ```
  # manager.enqueue(MyJob.new(5), at: Time.now + 5.minutes)
  # ```
  def enqueue(job : Job, **nargs)
    enqueue(job.class.to_s, job.to_json, **nargs)
  end

  # Enqueue a *job* by its class (will be instantiated without arguments).
  # See [`#enqueue`](#enqueue%28classklass%3AString%2Cpayload%3AString%3D%26quot%3B%7B%7D%26quot%3B%2C%2A%2Cqueue%3AString%3D%26quot%3Bdefault%26quot%3B%2Cin%3ATime%3A%3ASpan%3F%3Dnil%2Cat%3ATime%3F%3Dnil%29-instance-method) for options.
  #
  # Example:
  #
  # ```
  # manager.enqueue(MyJob, in: 5.minutes)
  # ```
  def enqueue(job : Job.class, **nargs)
    enqueue(job.to_s, **nargs)
  end

  # Enqueue a job by its *class* name with JSON *payload*.
  #
  # Arguments:
  #
  # * *queue* -- a queue to put the job in
  # * *in* -- a time span to queue the job in
  # * *at* -- a time to queue the job at
  #
  # Example:
  #
  # ```
  # manager.enqueue("SomeNamespace::MyJob", %Q[{"foo":"bar"}], queue: "regular", in: 5.minutes)
  # ```
  def enqueue(
    class klass : String,
    payload : String = "{}",
    *,
    queue : String = "default",
    in : Time::Span? = nil,
    at : Time? = nil
  )
    uuid = UUID.random

    case redis
    when Redis
      redis.as(Redis).pipelined do |pipe|
        save_job(pipe)
      end
    else
      save_job(redis)
    end

    return uuid
  end

  private macro save_job(client)
    job = Hash(String, String).new
    job["que"] = queue
    job["cls"] = klass
    job["arg"] = payload

    now = Time.now

    job["qat"] = now.to_unix_ms.to_s # Time the job was queued

    if in || at
      at ||= now + in.not_nil!
      job["pat"] = at.to_unix_ms.to_s # Time the job was originally scheduled to be processed at
    end

    pre_save_pro
    pre_save_ent

    # Add the job to Redis
    {{client}}.hmset("#{@namespace}:jobs:#{uuid}", job)

    if at
      # Add the job to the scheduled queue with score = at
      {{client}}.zadd("#{@namespace}:queues:scheduled:#{queue}", at.to_unix_ms, uuid.to_s)
    else
      # Add the job to the ready-to-go queue for immediate processing
      {{client}}.rpush("#{@namespace}:queues:ready:#{queue}", uuid)
    end
  end

  private macro pre_save_pro
  end

  private macro pre_save_ent
  end

  # Remove a job by its *job_uuid*.
  # Raises `JobNotFoundByUUID` if the job itself is not found or its queue in `nil`.
  # Returns falsey value if the job is not in the queue,
  # which means it's either already performed, removed or never been there.
  def dequeue(job_uuid uuid : UUID | String)
    queue = redis.hget("#{@namespace}:jobs:#{uuid}", "que")
    raise JobNotFoundByUUID.new(uuid) unless queue

    case redis
    when Redis
      _, scheduled, ready = redis.as(Redis).multi do |multi|
        multi.del("#{@namespace}:jobs:#{uuid}")
        multi.zrem("#{@namespace}:queues:scheduled:#{queue}", uuid)
        multi.lrem("#{@namespace}:queues:ready:#{queue}", 0, uuid)
      end
    else
      redis.del("#{@namespace}:jobs:#{uuid}")
      scheduled = redis.zrem("#{@namespace}:queues:scheduled:#{queue}", uuid)
      ready = redis.lrem("#{@namespace}:queues:ready:#{queue}", 0, uuid)
    end

    return (scheduled && scheduled.as(Int64) > 0) || (ready && ready.as(Int64) > 0)
  end
end
