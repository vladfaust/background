<a href="https://onyxframework.org"><img align="right" width="147" height="147" src="https://onyxframework.org/img/logo.svg"></a>

# Onyx::Background

[![Built with Crystal](https://img.shields.io/badge/built%20with-crystal-000000.svg?style=flat-square)](https://crystal-lang.org)
[![Travis CI build](https://img.shields.io/travis/com/onyxframework/background/master.svg?style=flat-square)](https://travis-ci.com/onyxframework/background)
[![API docs](https://img.shields.io/badge/api_docs-online-brightgreen.svg?style=flat-square)](https://api.onyxframework.org/background)
[![Latest release](https://img.shields.io/github/release/onyxframework/background.svg?style=flat-square)](https://github.com/onyxframework/background/releases)

A fast background job processing for [Crystal](https://crystal-lang.org).

## About

This is a [Redis](https://redis.io)-based background jobs processing for [Crystal](https://crystal-lang.org), alternative to [sidekiq](https://github.com/mperham/sidekiq.cr) and [mosquito](https://github.com/robacarp/mosquito). It's a component of [Onyx Framework](https://github.com/onyxframework), but can be used separately.

### Goals

Just like all other [@onyxframework](https://github.com/onyxframework) components, Onyx::Background aims to be as much novice-friendly as possible, still being able to scale with a developer's knowledge of Crystal, thus having these goals:

* Speed — taking the best from Crystal performance
* Simplicity — the shard API is simpler than alternatives'
* Modularity — most of the components are replaceable
* Expandability — every component may be re-opened and added with new functionality
* Failure-safety — the whole system is stateless, allowing any of its parts to fail and re-run safely without locking overhead
* No Crystal lock-in — a simple manager can be written in any language with Redis driver

### Features

This publicly available open-source version has the following functionality:

* Enqueuing jobs for immediate processing
* Enqueuing jobs for delayed processing (i.e. `in: 5.minutes` or `at: Time.now + 1.hour`)
* Different job queues (`"default"` by default)
* Concurrent jobs processing (with a separate Redis client for each fiber)
* Verbose Redis logging of all the activity (i.e. every attempt made)
* Rescuing errors and moving failed jobs to the failed list
* Moving stale jobs (i.e. with dead workers) to the failed list
* CLI

If you want more features and professional support, consider purchasing a commercial license at [onyxframework.com](https://onyxframework.com).

### Performance

Thorough benchmaring is to be done yet, however, currently it is able to process more than **9000 jobs per second** on my 0.9GHz machine with Redis instance running on itself.

![It's over 9000!](https://vignette.wikia.nocookie.net/dragonball/images/4/4b/VegetaItsOver9000-02.png/revision/latest?cb=20100724145819)

## Installation

> ⚠️ **Note:** Onyx::Background works with Redis version `~> 5.0`

Add this to your application's `shard.yml`:

```yaml
dependencies:
  onyx-background:
    github: onyxframework/background
    version: ~> 0.1.0
```

This shard follows [Semantic Versioning v2.0.0](http://semver.org/), so check [releases](https://github.com/onyxframework/background/releases) and change the `version` accordingly.

## Usage

### API docs

Please refer to API documentation available online: [https://api.onyxframework.org/background](https://api.onyxframework.org/background)

> **Note:** it is automatically updated on every master branch commit

### Example

```crystal
require "onyx-background"

struct Jobs::Nap
  include Onyx::Background::Job

  def initialize(@sleep : Int32 = 1)
  end

  def perform
    sleep(@sleep)
  end
end

manager = Onyx::Background::Manager.new
manager.enqueue(Jobs::Nap.new)

puts "Enqueued"

logger = Logger.new(STDOUT, Logger::DEBUG)
worker = Onyx::Background::Worker.new(logger: logger)
worker.run
```

```console
$ crystal app.cr
Enqueued
I -- worker: Working...
D -- worker: Waiting for a new job...
D -- worker: [fa5b6d65-46fe-4c88-829f-d69023c4c6de] Attempting
D -- worker: [fa5b6d65-46fe-4c88-829f-d69023c4c6de] Performing Jobs::Nap {"sleep":1}...
D -- worker: Waiting for a new job...
D -- worker: [fa5b6d65-46fe-4c88-829f-d69023c4c6de] Completed
```

It's also highly recommended to run a Watcher process to watch for stale jobs. If you're queuing delayed jobs, the Watcher is **required** to move the jobs to the ready queue on time:

```crystal
# watcher.cr
require "onyx-background"

watcher = Onyx::Background::Watcher.new
watcher.run
```

### CLI

A simple [`Onyx::Background::CLI`](https://api.onyxframework.org/background/Onyx/Background/CLI.html) is used to interact with Onyx::Background.

```crystal
# src/background-cli.cr
require "onyx-background/cli"
```

```console
$ crystal build -o cli src/background-cli.cr
$ ./cli -h
usage:
    onyx-background-cli [command] [options]
commands:
    status                           Display system status
options:
    -h, --help                       Show this help
```

#### Status

The `status` command displays the current system status:

```console
$ ./cli status -h
usage:
    onyx-background-cli status [options]
options:
    -q, --queue QUEUE                Comma-separated queue(s) ("default")
    -r, --redis REDIS_URL            Redis URL
    -n, --namespace NAMESPACE        Redis namespace ("onyx-background")
    -v, --verbose                    Enable verbose mode
    -h, --help                       Show this help
```

```console
$ ./cli status -q high,low
high
workers fibers  jps ready scheduled processing  completed failed
      4      4    0     0         0          0     500000      0

low
workers fibers  jps ready scheduled processing  completed failed
      0      0    0     0         0          0          0      0
```

> **Tip:** use `watch -n 1 ./cli status` to continuously monitor the status


## Architecture

In this section the system architecture is explained.

### Storing a job

> **Tip:** only this functionality is likely to be implemented in another language driver

A *job* hash is saved into Redis with an unique UUID at `"jobs:<uuid>"` key after [`Onyx::Background::Manager#enqueue`](https://api.onyxframework.org/background/Onyx/Background/Manager.html#enqueue%28job%3AJob%2C%2A%2Anargs%29-instance-method) call:

```crystal
manager = Onyx::Background::Manager.new
manager.enqueue(Jobs::Nap.new, in: 5.minutes)
```

Key | Example | Description
--- | --- | ---
que | default | The job's queue
cls | Jobs::Nap | The job's class, should be available in the Worker program
arg | {"sleep":1} | The job's arguments, usually a JSON string
qat | 1545906554934 | The time the job's been queued at
pat | 1545906870368 | The time the job's been scheduled to be processed at (none if immediate)

The job UUID is also pushed to the `"ready:<queue>"` list or `"scheduled:<queue>"` sorted set (with score equal to scheduled time in milliseconds) for further processing.

### Working

When an [`Onyx::Background::Worker`](https://api.onyxframework.org/background/Onyx/Background/Worker.html) runs, its Redis client name is set to `"onyx-background-worker:<queues>"` (with comma-separated queues this worker is watching). It then `BLPOP`s the `"ready:<queue>"` list and spawns a separate fiber with a new instance of Redis client (it's pooled internally for better performance) for every popped job UUID.

This fiber's Redis client name is set to `"onyx-background-worker-fiber:<worker_client_id>"`. Afterwards it saves an unique *attempt* hash for a particular job at `"attempts:<attempt_uuid>"` key, which looks like this:

Key | Example | Description
--- | --- | ---
sta | 1545907080109 | The time the attempt was started at
job | d62f4c9a-... | The job's UUID
wrk | 342 | The fiber's Redis client ID
que | default | The actual processing queue

And adds the attempt UUID to the `"processing:<queue>"` set.

Thereafter, in case of successful job processing, the attempt is updated with finished at and processing time values:

Key | Example | Description
--- | --- | ---
fin | 1545907080110 | The time the attempt was finished at
time | 1.0 | The job processing time, in milliseconds

If the job raised an error, the attempt is updated with these values:

Key | Example | Description
--- | --- | ---
fin | 1545907080110 | The time the attempt was finished at
time | 1.0 | The job processing time, in milliseconds
err | IndexOutOfBounds | The unhandled exception class

The attempt UUID is then removed from the `"processing:<queue>"` set and added into `"completed:<queue>"` or `"failed:<queue>"` sorted set (with score equal to current time in milliseconds) depending on the result.

### Watching

[Onyx::Background::Watcher](https://api.onyxframework.org/background/Onyx/Background/Watcher.html) is used to watch for stale attempts (which workers are offline) and move jobs from the `"scheduled:<queue>"` sorted set to the `"ready:<queue>"` list:

```crystal
require "onyx-background"

watcher = Onyx::Background::Watcher.new
watcher.run
```

The watcher loops every *interval* (defaults to 1 second) and does the following:

1. Gets all the clients list from Redis and compares it with attempts stored in the `"processing:<queue>"` set. If an attempt's fiber client ID (the `"wrk"` key) is not found in the list of active clients, it's considered stale then and fails with a `"Worker Timeout"` error
2. Gets all jobs from `"scheduled:<queue>"` sorted set which have a score less than `Time.now.to_unix_ms` and moves them to the `"ready:<queue>"` list.

> ⚠️ **Note:** in case of multiple watchers watching the same queue, a duplication error may appear!

For a deeper understaing of the architecture, feel free to dive into the source code, it's quite well documented!

## Development

Redis is flushed during the spec, so you **must** specify a safe-to-flush Redis database in the `REDIS_URL`. To run the specs, use the following command:

```console
$ env REDIS_URL=redis://localhost:6379/1 crystal spec
```

## Contributing

1. Fork it (<https://github.com/onyxframework/background/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request


## Contributors

- [Vlad Faust](https://github.com/vladfaust) - creator and maintainer

## Licensing

This software is licensed under [BSD 3-Clause License](LICENSE).

[![Open Source Initiative](https://upload.wikimedia.org/wikipedia/commons/thumb/4/42/Opensource.svg/100px-Opensource.svg.png)](https://opensource.org/licenses/BSD-3-Clause)
