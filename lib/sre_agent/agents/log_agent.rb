module SreAgent
  module Agents
    # ログ担当サブエージェント。VictoriaLogs を横断的に検索し、傾向や不審な動きを探す。
    module LogAgent
      extend ToolHelpers
      module_function

      def build(config:, vl:, client:, bus:)
        logs = config.dig(:watch, :logs, default: {})
        host_field = logs["host_field"] || "hostname"
        sec = Array(logs["security_patterns"]).map { |p| "- #{p['name']}: #{p['query']}" }.join("\n")

        system = <<~TXT
          あなたは#{config.site}のログ分析担当SREです。統括エージェントからの依頼に答えます。
          ログは VictoriaLogs に syslog として入っています。主なフィールド:
          _time(時刻), _msg(本文), #{host_field}(送信元ホスト), app_name(プログラム名), severity(重大度)。
          LogsQL の例: error / "Rejected at" / #{host_field}:"rtx1300" / severity:~"err|crit" / -app_name:"cron"
          時間範囲はツールの minutes で指定するので、クエリに _time: は書かないでください。

          セキュリティ観点で見ている既知のパターン:
          #{sec.empty? ? '(なし)' : sec}

          調べ方の目安: いきなり全文を読まず、count_logs でホスト別・プログラム別の偏りを見てから、
          log_timeline でいつ増えたかを確かめ、search_logs で実際の行を読みます。
          同じ文面が大量にある場合は代表的な数行だけ引用し、件数で示してください。

          #{ToolHelpers::COMMON_RULES}
        TXT

        tools = [
          tool("search_logs", "LogsQLでログを検索し新しい順に返す",
               { query: str("LogsQL(_time:は不要)"), minutes: int("過去何分(既定15、最大1440)"), limit: int("最大件数(既定50)") },
               required: %w[query]) do |i, _r|
            vl.recent(i["query"], minutes: clamp_minutes(i["minutes"]), limit: (i["limit"] || 50).to_i.clamp(1, 200))
              .map { |r| { time: r["_time"], host: r[host_field], app: r["app_name"], sev: r["severity"], msg: r["_msg"] } }
          end,

          tool("count_logs", "条件に合うログ件数をフィールド別に集計する",
               { query: str("LogsQL"), by: str("集計キー(例: #{host_field}, app_name, severity)"), minutes: int("過去何分(既定60)") },
               required: %w[query by]) do |i, _r|
            vl.count_by(i["query"], field: i["by"], minutes: clamp_minutes(i["minutes"], default: 60))
          end,

          tool("log_timeline", "条件に合うログ件数の時間推移を返す",
               { query: str("LogsQL"), minutes: int("過去何分(既定120)"), step: str("集計間隔(例: 1m, 5m, 1h)") },
               required: %w[query]) do |i, _r|
            vl.timeline(i["query"], minutes: clamp_minutes(i["minutes"], default: 120), step: i["step"] || "5m")
          end
        ]

        Agent.new(name: "logs", label: "ログ", model: config.dig(:claude, :subagent_model),
                  system: system, tools: tools, client: client, bus: bus,
                  max_turns: config.dig(:claude, :subagent_max_turns, default: 8))
      end
    end
  end
end
