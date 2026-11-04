require "socket"
require "json"
require "timeout"
require "uri"

module SreAgent
  # 標準ライブラリだけで書いた小さなHTTPサーバ。ダッシュボード、JSON API、SSE を返す。
  # 前段にTraefik(TLS終端とOAuth)を置く前提なので、ここでは認証を持たない。
  class WebServer
    STATIC = {
      "/" => ["index.html", "text/html; charset=utf-8"],
      "/assets/app.js" => ["app.js", "application/javascript; charset=utf-8"],
      "/assets/style.css" => ["style.css", "text/css; charset=utf-8"]
    }.freeze

    AGENT_EVENTS = %w[agent.start agent.text agent.tool_call agent.tool_result agent.done agent.error agent.skipped
                      incident.opened incident.updated incident.resolved incident.investigating incident.report watcher.error].freeze

    def initialize(host:, port:, bus:, store:, watcher:, client:, config:, public_dir:)
      @host = host
      @port = port
      @bus = bus
      @store = store
      @watcher = watcher
      @client = client
      @config = config
      @public_dir = public_dir
    end

    def start
      @server = TCPServer.new(@host, @port)
      Thread.new do
        loop do
          sock = @server.accept
          Thread.new(sock) { |s| handle(s) }
        end
      end
      self
    end

    private

    def handle(sock)
      req = Timeout.timeout(10) { read_request(sock) }
      return sock.close unless req

      route(sock, req)
    rescue StandardError => e
      respond(sock, 500, { error: e.message }) rescue nil
    ensure
      sock.close unless sock.closed? || req&.dig(:sse)
    end

    def read_request(sock)
      line = sock.gets("\r\n") or return nil
      method, target, = line.split(" ", 3)
      headers = {}
      while (h = sock.gets("\r\n")) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip
      end
      len = headers["content-length"].to_i
      raise "リクエストが大きすぎます" if len > 16_384

      body = len.positive? ? sock.read(len) : ""
      path, query = target.to_s.split("?", 2)
      { method: method, path: path, query: URI.decode_www_form(query.to_s).to_h, headers: headers, body: body }
    end

    def route(sock, req)
      m = req[:method]
      p = req[:path]
      case [m, p]
      in ["GET", path] if STATIC.key?(path)
        file, type = STATIC[path]
        send_raw(sock, 200, type, File.read(File.join(@public_dir, file)), cache: false)
      in ["GET", "/healthz"]
        respond(sock, 200, { ok: true })
      in ["GET", "/api/state"]
        respond(sock, 200, state)
      in ["GET", "/api/incidents"]
        respond(sock, 200, @store.list(limit: 100))
      in ["GET", %r{\A/api/incidents/([\w-]+)\z}]
        inc = @store.get(Regexp.last_match(1))
        inc ? respond(sock, 200, inc) : respond(sock, 404, { error: "not found" })
      in ["GET", "/api/usage"]
        respond(sock, 200, @client&.usage || {})
      in ["GET", "/events"]
        req[:sse] = true
        stream(sock, req)
      in ["POST", _] unless req[:headers]["x-requested-with"] == "sre-dashboard"
        respond(sock, 403, { error: "missing X-Requested-With" })
      in ["POST", "/api/ask"]
        q = JSON.parse(req[:body].to_s)["question"].to_s.strip
        return respond(sock, 400, { error: "質問が空です" }) if q.empty?

        respond(sock, 202, @watcher.enqueue_inquiry(q[0, 1000]))
      in ["POST", %r{\A/api/incidents/([\w-]+)/investigate\z}]
        @watcher.enqueue_investigation(Regexp.last_match(1))
        respond(sock, 202, { queued: true })
      in ["POST", %r{\A/api/incidents/([\w-]+)/ack\z}]
        inc = @store.acknowledge(Regexp.last_match(1))
        @bus.emit("incident.updated", incident: inc) if inc
        respond(sock, 200, inc || {})
      else
        respond(sock, 404, { error: "not found" })
      end
    rescue RuntimeError, JSON::ParserError => e
      respond(sock, 400, { error: e.message })
    end

    def state
      {
        site: @config.site, grafana_url: @config.grafana_url, last_event_id: @bus.last_id,
        snapshot: @watcher.snapshot, agent: @watcher.status, incidents: @store.list(limit: 60),
        activity: @bus.recent(400, types: AGENT_EVENTS).map(&:to_h)
      }
    end

    # Server-Sent Events。ブラウザの EventSource が切れても Last-Event-ID から続きを受け取れる。
    def stream(sock, req)
      after = (req[:headers]["last-event-id"] || req[:query]["after"]).to_s
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n" \
                 "Cache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n")
      sock.write("retry: 3000\n\n")
      token, q = @bus.subscribe(after_id: after.empty? ? @bus.last_id : after.to_i)
      Thread.new do
        loop do
          ev = Timeout.timeout(15) { q.pop } rescue nil
          if ev
            sock.write("id: #{ev.id}\nevent: #{ev.type}\ndata: #{JSON.generate(ev.to_h)}\n\n")
          else
            sock.write(": ping\n\n")
          end
        end
      rescue IOError, SystemCallError
        nil
      ensure
        @bus.unsubscribe(token)
        sock.close unless sock.closed?
      end
    end

    def respond(sock, code, obj)
      send_raw(sock, code, "application/json; charset=utf-8", JSON.generate(obj))
    end

    def send_raw(sock, code, type, body, cache: false)
      body = body.b
      reason = { 200 => "OK", 202 => "Accepted", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 500 => "Internal Server Error" }[code]
      sock.write("HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                 "#{cache ? '' : "Cache-Control: no-store\r\n"}X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n")
      sock.write(body)
    end
  end
end
