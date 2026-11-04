require "yaml"

module SreAgent
  # config.yml を読み込み、${ENV_NAME} を環境変数で置き換える。
  # 秘密情報(APIキー、Proxmoxトークン)はファイルに書かず環境変数で渡す前提。
  class Config
    attr_reader :raw

    def self.load(path)
      text = File.read(path).gsub(/\$\{(\w+)\}/) { ENV.fetch(Regexp.last_match(1), "") }
      new(YAML.safe_load(text, aliases: true) || {})
    end

    def initialize(raw)
      @raw = raw
    end

    def dig(*keys, default: nil)
      v = @raw.dig(*keys.map(&:to_s))
      v.nil? ? default : v
    end

    def site = dig(:site, default: "DC")
    def data_dir = dig(:data_dir, default: "./data")
    def grafana_url = dig(:grafana_url)
  end
end
