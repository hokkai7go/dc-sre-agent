module SreAgent
  module Sources
    # VictoriaMetrics の Prometheus 互換クエリAPI。
    class VictoriaMetrics
      def initialize(url:, **opts)
        @http = HttpGet.new(url, **opts)
      end

      # 瞬時値。[{labels => {...}, value => Float}] を返す。
      def query(promql, time: nil)
        res = @http.get_json("/api/v1/query", { query: promql, time: time })
        raise SourceError, "PromQLエラー: #{res['error']}" unless res["status"] == "success"

        Array(res.dig("data", "result")).map do |r|
          { "labels" => r["metric"], "value" => r.dig("value", 1).to_f }
        end
      end

      # 範囲クエリ。トークン節約のため系列ごとに min/max/avg/last と間引いた点だけ返す。
      def query_range_summary(promql, minutes: 60, step: nil, max_series: 30, points: 12)
        now = Time.now.to_i
        step ||= [(minutes * 60 / 120), 15].max
        res = @http.get_json("/api/v1/query_range",
                             { query: promql, start: now - minutes * 60, end: now, step: "#{step}s" })
        raise SourceError, "PromQLエラー: #{res['error']}" unless res["status"] == "success"

        series = Array(res.dig("data", "result"))
        out = series.first(max_series).map do |r|
          vals = r["values"].map { |_, v| v.to_f }
          stride = [(r["values"].size / points.to_f).ceil, 1].max
          {
            "labels" => r["metric"],
            "min" => vals.min&.round(4), "max" => vals.max&.round(4),
            "avg" => vals.empty? ? nil : (vals.sum / vals.size).round(4),
            "last" => vals.last&.round(4),
            "samples" => r["values"].each_slice(stride).map(&:last).map { |t, v| [Time.at(t).strftime("%H:%M"), v.to_f.round(4)] }
          }
        end
        { "series_total" => series.size, "series" => out }
      end
    end
  end
end
