require "./manager_spec"

class Onyx::Background::Worker
  class SimpleJob
    include Job

    def initialize(@text : String)
    end

    def perform
      redis.set("onyx_background_worker_simple_job", @text)
    end
  end

  class FailingJob
    include Job

    def initialize
    end

    def perform
      raise ArgumentError.new("Oops")
    end
  end

  describe self do
    manager = Manager.new(redis, namespace)
    worker = self.new(
      redis_proc: ->{ redis },
      namespace: namespace,
      logger: Logger.new(STDOUT, level: Logger::DEBUG, progname: "worker")
    )

    spawn do
      worker.run
    end

    client = redis

    context "valid processing" do
      job_uuid = manager.enqueue(SimpleJob.new("foo"))
      sleep(1) # Only sleep for 1 second because the worker should process the job immediately

      it "actually completes the job" do
        redis.get("onyx_background_worker_simple_job").should eq "foo"
      end

      attempt_uuid = uninitialized String

      it "adds attempt to completed list" do
        attempt_uuid, _ = client.zpopmax("#{namespace}:completed", 1).as(Array).map(&.as(String))
        attempt_uuid.should be_truthy
      end

      it "does not add attempt to failed list" do
        client.zcard("#{namespace}:failed").should eq 0
      end

      it "doesn't persist attempt in processing list" do
        client.scard("#{namespace}:processing").should eq 0
      end

      it "saves attempt data" do
        hash = client.fetch_hash("#{namespace}:attempts:#{attempt_uuid}")

        started_at = Time.unix_ms(hash["sta"].to_i64)
        started_at.should be_a(Time)

        hash["job"].should eq job_uuid.to_s
        (hash["wrk"].to_i > 0).should be_true

        finished_at = Time.unix_ms(hash["fin"].to_i64)
        finished_at.should be_a(Time)

        (started_at <= finished_at).should be_true

        # `* 1000 * 1000` to convert millis to nanos
        # See https://github.com/crystal-lang/crystal/issues/7143
        processing_time = Time::Span.new(nanoseconds: (hash["tim"].to_f64 * 1000 * 1000).round.to_i64)
        (processing_time > Time::Span.zero).should be_true

        hash["err"]?.should be_nil
      end
    end

    context "failing job" do
      job_uuid = manager.enqueue(FailingJob)
      sleep(1) # Only sleep for 1 second because the worker should process the job immediately

      attempt_uuid = uninitialized String

      it "adds attempt to failed list" do
        attempt_uuid, _ = client.zpopmax("#{namespace}:failed", 1).as(Array).map(&.as(String))
        attempt_uuid.should be_truthy
      end

      it "does not add attempt to completed list" do
        client.zcard("#{namespace}:completed").should eq 0
      end

      it "doesn't persist attempt in processing list" do
        client.scard("#{namespace}:processing").should eq 0
      end

      it "saves attempt data" do
        hash = client.fetch_hash("#{namespace}:attempts:#{attempt_uuid}")

        started_at = Time.unix_ms(hash["sta"].to_i64)
        started_at.should be_a(Time)

        hash["job"].should eq job_uuid.to_s
        (hash["wrk"].to_i > 0).should be_true

        finished_at = Time.unix_ms(hash["fin"].to_i64)
        finished_at.should be_a(Time)

        (started_at <= finished_at).should be_true

        processing_time = Time::Span.new(nanoseconds: (hash["tim"].to_f64 * 1000 * 1000).round.to_i64)
        (processing_time > Time::Span.zero).should be_true

        hash["err"].should eq "ArgumentError"
      end
    end

    describe "stopping" do
      worker.stop(redis)

      sleep(1)

      it do
        worker.running?.should eq false
      end
    end
  end
end
