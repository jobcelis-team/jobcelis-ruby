# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "json"
require "jobcelis"

# Minimal HTTP server that answers each request with the next scripted response.
# A response of :drop closes the connection without answering (a network error).
class FakeServer
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

  attr_reader :requests

  def initialize(responses)
    @responses = responses.dup
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      socket = @server.accept
      handle(socket)
    rescue IOError, SystemCallError
      next
    end
  end

  def handle(socket)
    request_line = socket.gets or return socket.close
    method, path, = request_line.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i) if headers["content-length"]
    @requests << Request.new(method: method, path: path, headers: headers, body: body)

    response = @responses.shift || { status: 500, body: { error: "no response scripted" } }
    if response == :drop
      socket.close
      return
    end

    payload = response.key?(:body) ? JSON.generate(response[:body]) : ""
    extra = (response[:headers] || {}).map { |k, v| "#{k}: #{v}\r\n" }.join
    socket.write("HTTP/1.1 #{response[:status]} X\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n#{extra}\r\n#{payload}")
    socket.close
  end
end
