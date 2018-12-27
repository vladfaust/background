require "option_parser"
require "redis"
require "time_format"

require "./namespace"
require "./ext/redis/commands"

# The Command Line Interface module. Require it to automatically parse program arguments:
#
# ```
# # src/cli.cr
# require "onyx-background/cli"
# ```
#
# You can run the CLI with `crystal` command, using `--` as arguments delimeter:
#
# ```console
# $ crystal src/cli.cr -- status -v
# ```
#
# Or you can build the CLI into a binary:
#
# ```console
# $ crystal build -o cli src/cli.cr --release
# $ ./cli -h
# usage:
#     onyx-background-cli [command] [options]
# commands:
#     status                           Display system status
# options:
#     -h, --help                       Show this help
# ```
module Onyx::Background::CLI
end

require "./cli/*"

case ARGV[0]?
when "status"
  Onyx::Background::CLI::Status.run
else
  OptionParser.parse! do |parser|
    parser.banner = <<-USAGE
    usage:
        onyx-background-cli [command] [options]
    commands:
        status                           Display system status
    options:
    USAGE

    parser.on("-h", "--help", "Show this help") do
      puts parser
      exit(0)
    end

    parser.invalid_option do |flag|
      STDERR.puts "ERROR: Unknown option #{flag}"
      STDERR.puts parser
      exit(1)
    end
  end
end
