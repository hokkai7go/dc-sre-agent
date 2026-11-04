module SreAgent
  module Sources
    # VictoriaLogs の LogsQL クエリAPI。応答は1行1JSONの形式。
    class VictoriaLogs
      def initialize(url:, **opts)
        @http = HttpGet.new(url, **opts)
      end

      def query(logsql, minutes: 15, limit: 100)
        body = @http.get("/select/logsql/query", { query: with_time(logsql, minutes), limit: limit })
        body.each_line.filter_map do |line|
          line = line.strip
          JSON.parse(line) unless line.empty?
        rescue JSON::ParserError
          nil
        end
      end

      # 新しい順に並べた直近ログ。
      def recent(logsql, minutes: 15, limit: 50)
        query("#{logsql} | sort by (_time desc) | limit #{limit.to_i}", minutes: minutes, limit: limit)
      end

      # フィールド別件数。[{field => value, "n" => Integer}]
      def count_by(logsql, field:, minutes: 15, top: 30)
        f = field.to_s.gsub(/[^\w.]/, "")
        rows = query("#{logsql} | stats by (#{f}) count() as n | sort by (n desc) | limit #{top.to_i}",
                     minutes: minutes, limit: top)
        rows.map { |r| { f => r[f], "n" => r["n"].to_i } }
      end

      # 時間帯ごとの件数推移。
      def timeline(logsql, minutes: 60, step: "5m")
        s = step.to_s[/\A\d+[smh]\z/] || "5m"
        rows = query("#{logsql} | stats by (_time:#{s}) count() as n | sort by (_time)", minutes: minutes, limit: 500)
        rows.map { |r| { "time" => r["_time"], "n" => r["n"].to_i } }
      end

      private

      def with_time(q, minutes)
        q = q.to_s.strip
        q = "*" if q.empty?
        "_time:#{minutes.to_i}m #{q}"
      end
    end
  end
end
