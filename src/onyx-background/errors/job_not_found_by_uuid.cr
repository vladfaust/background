require "../namespace"

class Onyx::Background
  # Common errors.
  module Errors
    # Raised when a job is not found by its `UUID`.
    class JobNotFoundByUUID < Exception
      getter uuid : UUID | String

      def initialize(@uuid)
        super("Job not found with UUID #{@uuid}")
      end
    end
  end
end
