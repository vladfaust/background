class Onyx::Background::Worker
  # :nodoc:
  # Time To Live for a connection in the Fiber Redis Pool. Defaults to `30.seconds`.
  property redis_pool_ttl : Time::Span
  @redis_pool_ttl = 30.seconds

  # :nodoc:
  # A time to wait for a connection from the Fiber Redis Pool. Defaults to `10.microseconds`.
  property redis_pool_wait : Time::Span
  @redis_pool_wait = 10.microseconds

  @redis_pool = Array(Redis).new
  @redis_pool_is_using = Hash(Redis, Bool).new
  @redis_pool_client_ids = Hash(Redis, Int64).new
  @redis_pool_last_used_at = Hash(Redis, Time::Span).new

  protected def redis_pool_cleanup(ttl = @redis_pool_ttl)
    now = Time.monotonic

    @redis_pool_last_used_at.each do |redis, time|
      if !@redis_pool_is_using[redis] && now - time >= ttl
        @redis_pool.delete(redis)
        @redis_pool_client_ids.delete(redis)
        @redis_pool_last_used_at.delete(redis)
        @redis_pool_is_using.delete(redis)

        redis.close
      end
    end
  end

  protected def redis_pool_clear(client _client : Redis)
    _client.multi do |multi|
      @redis_pool_client_ids.each do |client, id|
        multi.client_unblock(id, false)
        multi.client_kill(id)
      end

      @redis_pool_is_using.clear
      @redis_pool_client_ids.clear
      @redis_pool_last_used_at.clear
      @redis_pool.clear
    end

    @logger.debug("Cleared the pool")
  end

  protected def redis_pool_get(worker_client_id : Int64, wait = @redis_pool_wait)
    if @redis_pool.any?
      client = @redis_pool.pop
      client_id = @redis_pool_client_ids[client]
      @redis_pool_is_using[client] = true
    elsif @redis_pool_client_ids.size < @fibers
      client = @redis_proc.call
      client_id? = uninitialized Redis::Future

      client.multi do |multi|
        multi.client_setname("onyx-background-worker-fiber:#{worker_client_id}")
        client_id? = multi.client_id
      end

      client_id = client_id?.value.as(Int64)
      @redis_pool_client_ids[client] = client_id

      @redis_pool_is_using[client] = true
    else
      @logger.debug("Redis pool size limit exceeded, sleeping for #{wait.total_milliseconds.round(3)}ms")
      sleep(wait)
      return redis_pool_get(worker_client_id, wait)
    end

    return {client.not_nil!, client_id.not_nil!}
  end

  protected def redis_pool_return(redis : Redis)
    @redis_pool_last_used_at[redis] = Time.monotonic
    @redis_pool << redis
    @redis_pool_is_using[redis] = false
  end
end
