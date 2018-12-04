require "./worker_spec"

class Onyx::Background::Watcher
  class SimpleJob
    include Job

    def initialize
    end

    def perform
      redis.set("onyx_background_watcher_simple_job", "foo")
    end
  end

  class LongJob
    include Job

    def initialize
    end

    def perform
      sleep
    end
  end

  describe self do
    client = redis

    worker = Worker.new(
      redis_proc: ->{ redis },
      namespace: namespace,
      logger: Logger.new(STDOUT, level: Logger::DEBUG, progname: "worker")
    )

    worker_process = Process.fork do
      worker.run
    end

    manager = Manager.new(redis, namespace)

    watcher = self.new(
      redis: redis,
      namespace: namespace,
      logger: Logger.new(STDOUT, level: Logger::DEBUG, progname: "watcher"),
    )

    spawn do
      watcher.run
    end

    describe "moving jobs to ready queue" do
      manager.enqueue(SimpleJob, in: 1.second)
      sleep(5) # Give time to the watcher to process these ready jobs

      it "allows the job to be processed" do
        redis.get("onyx_background_watcher_simple_job").should eq "foo"
      end
    end

    describe "failing stale jobs" do
      2.times do
        manager.enqueue(LongJob)
      end

      sleep(1) # Give time to the worker to begin processing jobs
      worker_process.kill
      sleep(3) # Give time to the watcher to move staled jobs

      attempt_uuids = Array(String).new

      it "adds attempts to failed list" do
        one, _, two, _ = client.zpopmax("#{namespace}:failed", 2).as(Array).map(&.as(String))

        attempt_uuids << one
        attempt_uuids << two

        attempt_uuids.empty?.should be_false
      end

      it "doesn't persist attempts in processing list" do
        client.scard("#{namespace}:processing").should eq 0
      end

      it "updates attempts data" do
        attempt_uuids.each do |uuid|
          hash = client.fetch_hash("#{namespace}:attempts:#{uuid}")

          hash["fin"]?.should be_nil
          hash["err"].should eq "Worker Timeout"
        end
      end
    end

    describe "stopping" do
      watcher.stop
      sleep(3)

      it do
        watcher.running?.should be_false
      end
    end
  end
end
