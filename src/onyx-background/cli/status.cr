class Onyx::Background
  # This command allows to get the currnet system status.
  # It displays all needed data in your terminal:
  #
  # ```console
  # $ ./cli status -h
  # usage:
  #     onyx-background-cli status [options]
  # options:
  #     -q, --queue QUEUE                Comma-separated queue(s) ("default")
  #     -r, --redis REDIS_URL            Redis URL
  #     -n, --namespace NAMESPACE        Redis namespace ("onyx-background")
  #     -v, --verbose                    Enable verbose mode
  #     -h, --help                       Show this help
  # ```
  #
  # ```console
  # $ ./cli status -q high,low
  # high
  # workers fibers  jps ready scheduled processing  completed failed
  #       4      4    0     0         0          0     500000      0
  #
  # low
  # workers fibers  jps ready scheduled processing  completed failed
  #       0      0    0     0         0          0          0      0
  # ```
  module CLI::Status
    # :nodoc:
    class Queue
      def initialize(
        @queue : String,
        @ready : Int64? = nil,
        @scheduled : Int64? = nil,
        @processing : Int64? = nil,
        @completed : Int64? = nil,
        @failed : Int64? = nil
      )
      end

      def ==(other : self)
        self.queue == other.queue
      end

      def hash(hasher)
        hasher = @queue.hash(hasher)
      end

      getter queue
      property! ready, scheduled, processing, completed, failed
    end

    # :nodoc:
    record Worker, client_id : Int64, queues : Set(Queue)

    # :nodoc:
    record Fiber, client_id : Int64, worker : Worker do
      property worker
    end

    # :nodoc:
    def self.run
      started_at = Time.monotonic

      cli_namespace = "onyx-background"
      cli_redis_url = nil
      cli_queues = ["default"]
      cli_verbose = false

      OptionParser.parse! do |parser|
        parser.banner = <<-USAGE
        usage:
            onyx-background-cli status [options]
        options:
        USAGE

        parser.on("-q", "--queue QUEUE", "Comma-separated queue(s) (\"default\")") do |queues|
          cli_queues = queues.split(',')
        end

        parser.on("-r", "--redis REDIS_URL", "Redis URL") do |url|
          cli_redis_url = url
        end

        parser.on("-n", "--namespace NAMESPACE", "Redis namespace (\"onyx-background\")") do |namespace|
          cli_namespace = namespace
        end

        parser.on("-v", "--verbose", "Enable verbose mode") do
          cli_verbose = true
        end

        parser.on("-h", "--help", "Show this help") do
          puts parser
          exit(0)
        end

        parser.missing_option do |flag|
          STDERR.puts "ERROR: Option #{flag} must not be empty"
          exit(1)
        end

        parser.invalid_option do |flag|
          STDERR.puts "ERROR: Unknown option #{flag}"
          STDERR.puts parser
          exit(1)
        end
      end

      namespace = cli_namespace

      if cli_redis_url
        redis = Redis.new(url: cli_redis_url)
      else
        redis = Redis.new
      end

      queues = Set(Queue).new
      workers = Array(Worker).new
      fibers = Array(Fiber).new

      clients = redis.client_list.as(String).split("\n")

      {% begin %}
        {% props = %w(ready scheduled processing completed failed) %}

        cli_queues.not_nil!.each do |queue|
          queues.add(Queue.new(queue))
        end

        # Load all required queue values

        redis.multi do |multi|
          queues.select do |queue|
            cli_queues.nil? ? true : cli_queues.not_nil!.includes?(queue.queue)
          end.each do |queue|
            multi.echo(queue.queue)
            multi.llen("#{namespace}:ready:#{queue.queue}")
            multi.zcount("#{namespace}:scheduled:#{queue.queue}", "-inf", "+inf")
            multi.scard("#{namespace}:processing:#{queue.queue}")
            multi.zcount("#{namespace}:completed:#{queue.queue}", "-inf", "+inf")
            multi.zcount("#{namespace}:failed:#{queue.queue}", "-inf", "+inf")
          end
        end.each_slice(6, true) do |(queue, {{props.join(", ").id}})|
          # OPTIMIZE: Refactor to dry the code using the |queue| above
          queue_instance = queues.find{ |q| q.queue == queue }.not_nil!

          {% for prop in props %}
            queue_instance.{{prop.id}} = {{prop.id}}.as(Int64)
          {% end %}
        end
      {% end %}

      # Map clients to Workers and Fibers
      #

      orphan_fibers = Hash(Int64, Array(Int64)).new

      clients.each do |client|
        case client
        when /id=(?<client_id>\d+).+name=onyx-background-worker:(?<queues>[\w+\,]+) /
          client_id = $~["client_id"].to_i64
          worker_queues = $~["queues"].split(',').reduce(Set(Queue).new) do |set, q|
            queue = Queue.new(q)
            queues.add(queue)
            set.add(queue)
            set
          end

          worker = Worker.new(client_id, worker_queues)
          workers << worker

          if fiber_client_ids = orphan_fibers.delete(client_id)
            fiber_client_ids.each do |fiber_client_id|
              fibers << Fiber.new(fiber_client_id, worker)
            end
          end
        when /id=(?<client_id>\d+).+name=onyx-background-worker-fiber:(?<worker_id>\d+) /
          client_id = $~["client_id"].to_i64
          worker_id = $~["worker_id"].to_i64
          worker = workers.find { |w| w.client_id == worker_id }

          if worker
            fibers << Fiber.new(client_id, worker)
          else
            (orphan_fibers[worker_id] ||= Array(Int64).new) << client_id
          end
        end
      end

      raise "BUG: orphan fibers found: #{orphan_fibers.keys.join(", ")}" if orphan_fibers.size > 0

      now = Time.now

      first = true

      queues.to_a.sort { |a, b| a.queue <=> b.queue }.select do |queue|
        cli_queues.includes?(queue.queue)
      end.each do |queue|
        queue_workers = workers.select { |w| w.queues.includes?(queue) }
        queue_fibers = fibers.select { |f| queue_workers.includes?(f.worker) }

        jps = redis.zcount("#{namespace}:completed:#{queue.queue}", (now - 1.second).to_unix_ms, now.to_unix_ms)

        if first
          first = false
        else
          puts "\n"
        end

        puts "#{queue.queue}\n"

        puts "workers\tfibers\tjps\tready\tscheduled\tprocessing\tcompleted\tfailed"

        print queue_workers.size.to_s.rjust("workers".size)
        print "\t"

        print queue_fibers.size.to_s.rjust("fibers".size)
        print "\t"

        print jps.to_s.rjust("jps".size)
        print "\t"

        print queue.ready.to_s.rjust("ready".size)
        print "\t"

        print queue.scheduled.to_s.rjust("scheduled".size)
        print "\t"

        print queue.scheduled.to_s.rjust("processing".size)
        print "\t"

        print queue.completed.to_s.rjust("completed".size)
        print "\t"

        print queue.failed.to_s.rjust("failed".size)
        print "\n"
      end

      if cli_verbose
        url = (cli_redis_url || "redis://localhost:6379").not_nil!
        puts "\ntime\t#{"url".ljust(url.size)}\t#{"namespace".ljust(cli_namespace.size)}\tqueues"
        puts "#{TimeFormat.auto(Time.monotonic - started_at)}\t#{url}\t#{cli_namespace}\t#{cli_queues.join(',')}"
      end
    end
  end
end
