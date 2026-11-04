require "net/http"
require "openssl"
require "uri"
require "json"

module SreAgent
  module Sources
    class SourceError < StandardError; end

    # GET しか持たない HTTP クライアント。
    # エージェントが監視対象を変更できないことを、権限設定だけでなくコードの形でも担保する。
    class HttpGet
      def initialize(base_url, headers: {}, verify_tls: true, ca_file: nil, timeout: 20)
        @base = URI(base_url.to_s.chomp("/"))
        @headers = headers
        @verify_tls = verify_tls
        @ca_file = ca_file
        @timeout = timeout
      end

      def get(path, params = {})
        uri = @base.dup
        uri.path = "#{@base.path}#{path}"
        uri.query = URI.encode_www_form(params.compact) unless params.empty?
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = @verify_tls ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          http.ca_file = @ca_file if @ca_file && !@ca_file.empty?
        end
        http.open_timeout = 5
        http.read_timeout = @timeout
        req = Net::HTTP::Get.new(uri)
        @headers.each { |k, v| req[k] = v }
        res = http.request(req)
        raise SourceError, "#{@base.host} #{path} -> HTTP #{res.code}: #{res.body.to_s[0, 300]}" unless res.code.to_i == 200

        res.body.to_s.force_encoding("UTF-8")
      rescue SourceError
        raise
      rescue StandardError => e
        raise SourceError, "#{@base.host} に接続できません: #{e.class}: #{e.message}"
      end

      def get_json(path, params = {})
        JSON.parse(get(path, params))
      end
    end
  end
end
