module SreAgent
  module Agents
    module ToolHelpers
      module_function

      def tool(name, description, properties = {}, required: [], terminal: false, &handler)
        Agent::Tool.new(
          name: name, description: description, terminal: terminal,
          input_schema: { type: "object", properties: properties, required: required },
          handler: handler
        )
      end

      def str(desc, enum: nil) = { type: "string", description: desc }.tap { |h| h[:enum] = enum if enum }
      def int(desc) = { type: "integer", description: desc }
      def bool(desc) = { type: "boolean", description: desc }

      def clamp_minutes(v, default: 15, max: 1440)
        (v || default).to_i.clamp(1, max)
      end

      # RRDの時系列を項目ごとの min/max/avg/last に要約する。
      def summarize_rows(rows, skip: %w[time])
        rows = Array(rows)
        keys = rows.flat_map(&:keys).uniq - skip
        keys.to_h do |k|
          vals = rows.map { |r| r[k] }.select { |v| v.is_a?(Numeric) }
          next [k, nil] if vals.empty?

          [k, { "min" => vals.min.round(4), "max" => vals.max.round(4),
                "avg" => (vals.sum / vals.size).round(4), "last" => vals.last.round(4) }]
        end.compact
      end

      COMMON_RULES = <<~TXT.freeze
        共通ルール:
        - あなたは読み取り専用です。設定変更・再起動・停止などは実行できませんし、実行したかのように書いてはいけません。
        - ツールで確認した事実と、そこからの推測をはっきり分けて書いてください。推測には「推測:」と付けます。
        - データが取れなかった場合は、取れなかったこと自体を報告してください。値をでっち上げてはいけません。
        - 時刻は日本時間(JST)で書いてください。
        - 回答は日本語で、統括エージェントが読む前提の簡潔な報告にしてください(目安600字以内)。
          形式: 「結論」「確認した事実(機器名・値・時刻つき)」「推測」「追加で見るべき点」。
      TXT
    end
  end
end
