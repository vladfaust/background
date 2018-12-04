require "json"
require "./worker"

class Onyx::Background
  # Include this module to turn an object into an Onyx Job.
  #
  # When a Job is queued, its instance is serialized into JSON.
  # When a Job is extracted from the queue for performing, it's deserialized from JSON.
  #
  # This module includes `JSON::Serializable`, making *all* instance variables serializeable by default.
  #
  # ```
  # # This job will sleep for certain time.
  # struct MyJob
  #   include Onyx::Background::Job
  #
  #   # This variable in ignored on serialization
  #   @[JSON::Field(ignore: true)]
  #   @foo : String
  #
  #   def initialize(@sleep : Int32)
  #     @foo = "bar"
  #   end
  #
  #   def perform
  #     sleep(@sleep)
  #     puts "Completed!" # Will print into the worker STDOUT
  #   end
  # end
  #
  # background = Onyx::Background::Manager.new
  # job = MyJob.new(1)
  #
  # # Add the job to the "default" queue
  # manager.enqueue(job) # Will save it with {"sleep": 1} payload
  # ```
  module Job
    # Must be implemented by the including job.
    abstract def perform

    # Must be implemented by the including job.
    abstract def initialize

    @[JSON::Field(ignore: true)]
    @attempt_uuid : String | Nil

    # Return the current attempt UUID as a `String`. Usually set by `Worker`.
    def attempt_uuid : String
      @attempt_uuid.not_nil!
    end

    # The default queue for this job. Defaults to `"default"`.
    # Can be overwritten on `Manager#enqueue`.
    def self.queue : String
      raise NotImplementedError.new # See `.included` macro
    end

    # ditto
    def self.queue=(value : String)
      raise NotImplementedError.new # See `.included` macro
    end

    # :nodoc:
    def attempt_uuid=(value : String)
      @attempt_uuid = value
    end

    macro included
      include JSON::Serializable

      class_property queue : String
      @@queue = "default"

      protected def Onyx::Background::Worker.job_class(from : String)
        if from == {{@type.stringify}}
          return ::{{@type.name}}
        else
          previous_def
        end
      end

      included_pro
      included_ent
    end

    private macro included_pro
    end

    private macro included_ent
    end
  end
end
