# Onyx::Background

[![Built with Crystal](https://img.shields.io/badge/built%20with-crystal-000000.svg?style=flat-square)](https://crystal-lang.org)
[![Travis CI build](https://img.shields.io/travis/com/onyxframework/background/master.svg?style=flat-square)](https://travis-ci.com/onyxframework/background)
[![API docs](https://img.shields.io/badge/api_docs-online-brightgreen.svg?style=flat-square)](https://api.onyxframework.org/background)
[![Latest release](https://img.shields.io/github/release/onyxframework/background.svg?style=flat-square)](https://github.com/onyxframework/background/releases)

A fast background job processing for [Crystal](https://crystal-lang.org).

## About

This is a [Redis](https://redis.io)-based background jobs processing for [Crystal](https://crystal-lang.org) alternative to [sidekiq](https://github.com/mperham/sidekiq.cr) and [mosquito](https://github.com/robacarp/mosquito). It's a component of [Onyx Framework](https://github.com/onyxframework), but can be used separately.

### Features

This publicly available open-source version has the following functionality:

* Enqueuing jobs for immediate processing
* Enqueuing jobs for delayed processing (i.e. `in: 5.minutes` or `at: Time.now + 1.hour`)
* Different job queues (`"default"` by default)
* Concurrent jobs processing (with a separate Redis client for each fiber)
* Verbose Redis logging of all the activity (i.e. every attempt made)
* Moving stale jobs (i.e. with dead workers) to the failed list

### Performance

Thorough benchmaring is to be done yet, however, currently a single Worker is able to process more than **7500 jobs per second** on my 0.9GHz machine with Redis instance running on itself.

## Installation

Onyx::Background works with Redis version `~> 5.0`.

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

*Note: it is updated on every master branch commit*

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

This software is licensed under BSD 3-Clause License with "Commons Clause" License Condition v1.0. See [LICENSE](LICENSE).
