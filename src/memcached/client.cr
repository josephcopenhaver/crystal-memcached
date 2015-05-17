require "socket"

# This class is a client for memcached storage
#
# ** Usage **
# ```crystal
# # Require package
# require "memcached"
#
# # Create client instance
# client = Memcached::Client.new
#
# # Execute commands
# client.set("key", "value")
# client.set("another_key", "another_value")
# client.get("key")   # "value"
# client.get_multi(["key", "another_key"]) # { "key" => "value", "another_key" => "another_value"}
# client.delete("key")
# ```
module Memcached
  class Client
    #:nodoc:
    HEADER_SIZE = 24

    #:nodoc:
    MAGICS = {
      "request"  => 0x80_u8,
      "response" => 0x81_u8
    }

    #:nodoc:
    OPCODES = {
      "get"    => 0x00_u8,
      "set"    => 0x01_u8,
      "delete" => 0x04_u8,
      "getq"   => 0x09_u8,
      "noop"   => 0x0a_u8,
      "getk"   => 0x0c_u8,
      "getkq"  => 0x0d_u8
    }

    # Opens connection to memcached server
    #
    # **Options**
    # * host : String - memcached host
    # * port : Number - memcached port
    def initialize(host = "localhost", port = 11211)
      Memcached.logger.info("Connecting to #{host}:#{port}")
      @socket = TCPSocket.new(host, port)
      @io = BufferedIO.new(@socket)
    end

    #:nodoc:
    def finalize
      if !@socket.nil?
        @socket.close
      end
    end

    # Set key - value pair in memcached.
    #
    # By default the key is set without expiration time.
    # If you want to set TTL for the key,
    # pass TTL in seconds as *expire* parameter
    def set(key : String, value : String, expire = 0) : Bool
      send_request(
        OPCODES["set"],
        key.bytes,
        value.bytes,
        [
          0xde_u8, 0xad_u8, 0xbe_u8, 0xef_u8,
          ((expire >> 24) & 0xFF).to_u8
          ((expire >> 16) & 0xFF).to_u8
          ((expire >> 8) & 0xFF).to_u8
          (expire  & 0xFF).to_u8
        ]
      )
      @io.flush
      read_response.try do |response|
        response.successful? && response.opcode == OPCODES["set"]
      end || false
    end

    # Get single key value from memcached.
    #
    # Returns key value or *nil* if the key was not found or an error occured
    def get(key : String) : String?
      send_request(
        OPCODES["get"],
        key.bytes,
        Array(UInt8).new(0),
        Array(UInt8).new(0)
      )
      @io.flush
      read_response.try do |response|
        if response.successful? && response.opcode == OPCODES["get"]
          String.new(response.body)
        else
          nil
        end
      end
    end

    # Get multiple keys values from memcached.
    #
    # Returns Hash(String, String | Nil)
    # If a key was not found or an error occured,
    # value for this key will be nil in the returned hash
    def get_multi(keys : Array(String)) : Hash(String, String | Nil)
      result = Hash(String, String | Nil).new
      keys.each do |key|
        result[key] = nil
        send_request(
          OPCODES["getkq"],
          key.bytes,
          Array(UInt8).new(0),
          Array(UInt8).new(0)
        )
      end
      send_request(
        OPCODES["noop"],
        Array(UInt8).new(0),
        Array(UInt8).new(0),
        Array(UInt8).new(0)
      )
      @io.flush
      while response = read_response
        Memcached.logger.info(String.new(response.body))
        case response.opcode
        when OPCODES["noop"]
          return result
        when OPCODES["getkq"]
          key = String.new(response.body[0, response.key_length])
          value = String.new(
            response.body[
              response.key_length,
              response.body.length - response.key_length
            ]
          )
          result[key] = value
        end
      end
      result
    end

    # Deletes the key from memcached.
    def delete(key : String) : Bool
      send_request(
        OPCODES["delete"],
        key.bytes,
        Array(UInt8).new(0),
        Array(UInt8).new(0)
      )
      @io.flush
      read_response.try do |response|
        response.successful? && response.opcode == OPCODES["delete"]
      end || false
    end

    private def read_response
      response_header = Slice(UInt8).new(HEADER_SIZE)
      @socket.read_fully(response_header)
      if response_header[0] != MAGICS["response"]
        return nil
      end
      Memcached.logger.info("Response received")
      opcode = response_header[1]
      key_length = response_header[2].to_u32 << 8 |
        response_header[3].to_u32
      extras_length = response_header[4].to_i32
      total_length = response_header[8].to_u32 << 24 |
        response_header[9].to_u32 << 16 |
        response_header[10].to_u32 << 8 |
        response_header[11].to_u32
      body_length = (total_length - extras_length).to_i32
      Memcached.logger.info("Total length: #{total_length}, \
        extras_length: #{extras_length}, body_length: #{body_length}")
      status_code = response_header[7]
      Memcached.logger.info("Response status code: #{status_code}")
      extras = Slice(UInt8).new(extras_length)
      body = Slice(UInt8).new(body_length)
      if extras_length > 0
        @socket.read(extras)
      end
      if body_length > 0
        @socket.read(body)
      end
      Response.new(status_code, opcode, key_length, body, extras)
    end

    private def send_request(
      opcode : UInt8,
      key : Array(UInt8),
      value : Array(UInt8),
      extras : Array(UInt8)
    )
      extras_length = extras.length.to_u8
      key_length = key.length.to_u16
      total_length = (key.length + value.length + extras_length).to_u32
      # Header
      @io.write([
        MAGICS["request"],                              # magic 0
        opcode,                                         # opcode 1
        ((key_length >> 8) & 0xFF).to_u8,               # key length 2
        (key_length & 0xFF).to_u8,                      # key length 3
        extras_length,                                  # extra length 4
        0_u8                                            # data type 5
        0_u8, 0_u8,                                     # vbucket 6, 7
        ((total_length >> 24) & 0xFF).to_u8             # total body 8
        ((total_length >> 16) & 0xFF).to_u8             # total body 9
        ((total_length >> 8) & 0xFF).to_u8              # total body 10
        (total_length & 0xFF).to_u8                     # total body 11
        0_u8, 0_u8, 0_u8, 0_u8,                         # opaque 12, 13, 14, 15
        0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8  # cas 16, 17, 18, 19, 20, 21, 22, 23
      ])
      # Body
      if extras.length > 0
        @io.write(extras)
      end
      if key.length > 0
        @io.write(key)
      end
      if value.length > 0
        @io.write(value)
      end
    end
  end
end
