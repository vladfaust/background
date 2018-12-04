# Powerful framework for modern applications. See [onyxframework.org](https://onyxframework.org).
class Onyx
  # A fast background job processing for Crystal.
  class Background
    # Raised when a job is not found by its `UUID`.
    class JobNotFoundByUUID < Exception
      getter uuid : UUID | String

      def initialize(@uuid)
        super("Job not found with UUID #{@uuid}")
      end
    end
  end
end

require "./onyx-background/*"
