class Redis
  module Commands
    # Return a `Hash(String, String)` representation of hash stored at *key*.
    def fetch_hash(key : String)
      data = hgetall(key)
      hash = {} of String => String

      data.each_slice(2) do |(key, value)|
        hash[key.to_s] = value.to_s
      end

      hash
    end

    # Return a `Hash(String, String)` representation of hash *fields* stored at *key*.
    def fetch_hash(key : String, *fields)
      data = hmget(key, *fields)
      hash = {} of String => String | Nil

      fields.each_with_index do |field, i|
        hash[field] = data[i].try &.to_s
      end

      hash
    end

    # Return the client ID for the current connection. See [https://redis.io/commands/client-id](https://redis.io/commands/client-id).
    def client_id
      integer_command(["CLIENT", "ID"])
    end

    # Kill the connection of a client by its ID. See [https://redis.io/commands/client-kill](https://redis.io/commands/client-kill).
    def client_kill(id : Int)
      integer_command(["CLIENT", "KILL", "ID", id.to_s])
    end

    enum ClientType
      Normal
      Master
      Replica
      Pubsub
    end

    # Get the list of client connections. See [https://redis.io/commands/client-list](https://redis.io/commands/client-list).
    def client_list(type type? : ClientType? = nil)
      commands = ["CLIENT", "LIST"]

      if type = type?
        commands += ["TYPE", type.to_s.downcase]
      end

      string_command(commands)
    end

    # Get the current connection name. See [https://redis.io/commands/client-getname](https://redis.io/commands/client-getname).
    def client_getname
      string_or_nil_command(["CLIENT", "GETNAME"])
    end

    # Set the current connection name. See [https://redis.io/commands/client-setname](https://redis.io/commands/client-setname).
    def client_setname(name : String)
      string_command(["CLIENT", "SETNAME", name]) == "OK"
    end

    def client_unblock(id : Int, error error? : Bool = false)
      commands = ["CLIENT", "UNBLOCK", id.to_s]

      if error = error?
        commands << "ERROR"
      end

      integer_command(commands)
    end

    # Remove and return members with the highest scores in a sorted set.
    # See [https://redis.io/commands/zpopmax](https://redis.io/commands/zpopmax).
    def zpopmax(key : String, count count? : Int32? = nil)
      commands = ["ZPOPMAX", key]

      if count = count?
        commands << count.to_s
      end

      string_array_command(commands)
    end

    # Remove and return members with the lowest scores in a sorted set.
    # See [https://redis.io/commands/zpopmin](https://redis.io/commands/zpopmin).
    def zpopmin(key : String, count count? : Int32? = nil)
      commands = ["ZPOPMIN", key]

      if count = count?
        commands << count.to_s
      end

      string_array_command(commands)
    end
  end
end
