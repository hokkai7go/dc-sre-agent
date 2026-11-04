require "net/http"
require "json"
require "uri"

module SreAgent
  # Claude Messages API の薄いクライアント。gem に頼らず Net::HTTP だけで叩く。
  class ClaudeClient
    class Error < StandardError; end

    RETRYABLE = [408, 409, 429, 500, 502, 503, 504, 529].freeze

    attr_reader :usage

    def initialize(api_key:, base_url: "https://api.anthropic.com", timeout: 300, max_retries: 4)
      raise Error, "ANTHROPIC_API_KEY が設定されていません" if api_key.to_s.empty?

      @api_key = api_key
      @uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "v1/messages")
      @timeout = timeout
      @max_retries = max_retries
      @usage = Hash.new(0)
      @usage_mutex = Mutex.new
    end

    # system はキャッシュ指定付きのブロックにする。
    # 同じエージェントは毎回同じ system と tools を送るので、プロンプトキャッシュが効く。
    def messages(model:, system:, messages:, tools: [], max_tokens: 4096)
      tool_defs = tools.map(&:dup)
      tool_defs[-1] = tool_defs[-1].merge(cache_control: { type: "ephemeral" }) unless tool_defs.empty?
      body = {
        model: model,
        max_tokens: max_tokens,
        system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
        messages: messages
      }
      body[:tools] = tool_defs unless tool_defs.empty?
      res = post(body)
      track_usage(model, res["usage"])
      res
    end

    private

    class Retryable < StandardError
      attr_reader :wait

      def initialize(msg, wait)
        super(msg)
        @wait = wait
      end
    end

    def post(body)
      attempt = 0
      begin
        attempt += 1
        try_post(body, attempt)
      rescue Retryable => e
        raise Error, e.message if attempt > @max_retries

        sleep e.wait
        retry
      end
    end

    def try_post(body, attempt)
      begin
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = @timeout
        req = Net::HTTP::Post.new(@uri)
        req["x-api-key"] = @api_key
        req["anthropic-version"] = "2023-06-01"
        req["content-type"] = "application/json"
        req.body = JSON.generate(body)
        res = http.request(req)
        code = res.code.to_i
        return JSON.parse(res.body) if code == 200

        msg = "Claude API #{code}: #{res.body.to_s[0, 500]}"
        raise Retryable.new(msg, (res["retry-after"] || (2**attempt)).to_f.clamp(1, 60)) if RETRYABLE.include?(code)

        raise Error, msg
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, SocketError => e
        raise Retryable.new("Claude API 接続エラー: #{e.class}: #{e.message}", 2**attempt)
      end
    end

    def track_usage(model, usage)
      return unless usage

      @usage_mutex.synchronize do
        %w[input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens].each do |k|
          @usage["#{model}:#{k}"] += usage[k].to_i
        end
        @usage["#{model}:requests"] += 1
      end
    end
  end
end
