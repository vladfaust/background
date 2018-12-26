require "./spec_helper"

class Onyx::Background::Manager
  class SimpleJob
    include Job

    def initialize
    end

    def perform
    end
  end

  class ComplexJob
    include Job

    @bar : Int32

    @[JSON::Field(ignore: true)]
    @baz : String = "qux"

    def initialize(@foo : String, @bar)
    end

    def perform
    end
  end

  describe self do
    manager = new(redis, namespace)
    uuid = uninitialized UUID

    describe "#enqueue" do
      context "without args" do
        uuid = manager.enqueue(SimpleJob.new)

        it "stores the job as hash" do
          hash = redis.fetch_hash("#{namespace}:jobs:#{uuid}")
          hash["pat"]?.should be_nil
          Time.unix_ms(hash["qat"].to_i64).should be_a(Time)
          hash["que"].should eq "default"
          hash["cls"].should eq "Onyx::Background::Manager::SimpleJob"
          hash["arg"].should eq "{}"
        end

        it "puts the job into ready queue" do
          redis.lpop("#{namespace}:queues:ready:default").should eq uuid.to_s
        end
      end

      context "with payload and args" do
        uuid = manager.enqueue(ComplexJob.new("baz", 42), in: 1.minute, queue: "non-default")

        it "stores the job as hash" do
          hash = redis.fetch_hash("#{namespace}:jobs:#{uuid}")
          Time.unix_ms(hash["pat"].to_i64).should be_a(Time)
          Time.unix_ms(hash["qat"].to_i64).should be_a(Time)
          hash["que"].should eq "non-default"
          hash["cls"].should eq "Onyx::Background::Manager::ComplexJob"
          hash["arg"].should eq %Q[{"bar":42,"foo":"baz"}]
        end

        it "puts the job into scheduled queue" do
          redis.zrank("#{namespace}:queues:scheduled:non-default", uuid).should eq 0
        end

        it "does not put the job into ready queue" do
          redis.lrem("#{namespace}:queues:ready:non-default", 0, uuid).should eq 0
        end
      end
    end

    describe "#dequeue" do
      it do
        manager.dequeue(uuid).should be_true
      end

      it "removes the job itself" do
        redis.fetch_hash("#{namespace}:jobs:#{uuid}").empty?.should be_true
      end

      it "removes the job from queues" do
        redis.llen("#{namespace}:queues:scheduled:non-default").should eq 0
      end

      it "raises on non-existing UUID" do
        expect_raises Onyx::Background::Errors::JobNotFoundByUUID do
          manager.dequeue(uuid)
        end
      end
    end
  end
end
