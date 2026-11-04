module SreAgent
  module Agents
    # ネットワーク担当サブエージェント。
    # snmp_exporter / blackbox_exporter が VictoriaMetrics に入れたメトリクスと、機器のsyslogを読む。
    module NetworkAgent
      extend ToolHelpers
      module_function

      def build(config:, vm:, vl:, client:, bus:)
        net = config.dig(:watch, :network, default: {})
        devices = Array(net["devices"])
        ping_job = net["ping_job"] || "blackbox-icmp"
        host_field = config.dig(:watch, :logs, :host_field, default: "hostname")

        device_lines = devices.map do |d|
          "- #{d['name']}: instance=#{d['instance']} log_host=#{d['log_host'] || d['name']} 役割=#{d['role']}"
        end.join("\n")

        system = <<~TXT
          あなたは#{config.site}のネットワーク担当SREです。統括エージェントからの依頼に答えます。
          対象機器:
          #{device_lines.empty? ? '(設定なし。list_devicesで確認)' : device_lines}

          メトリクスは snmp_exporter(if_mib) と blackbox_exporter(ICMP) の標準的な名前です。
          例: probe_success, probe_duration_seconds, ifOperStatus, ifAdminStatus, ifHCInOctets, ifHCOutOctets,
          ifInErrors, ifOutErrors, ifInDiscards, ifHighSpeed, sysUpTime。ラベル instance が機器のアドレスです。
          調べ方の目安: まず list_devices で疎通を見て、怪しい機器は interface_status、
          その時間帯の機器ログは device_logs で確認します。帯域やエラーの推移は query_metrics に minutes を付けます。

          #{ToolHelpers::COMMON_RULES}
        TXT

        find_device = lambda do |key|
          devices.find { |d| [d["name"], d["instance"]].include?(key) } || { "name" => key, "instance" => key }
        end

        tools = [
          tool("list_devices", "監視対象ネットワーク機器の一覧と、現在のping疎通・応答時間・SNMP取得状況を返す") do |_i, _r|
            probe = vm.query(%(probe_success{job=~"#{ping_job}"}))
            rtt = vm.query(%(probe_duration_seconds{job=~"#{ping_job}"}))
            snmp = vm.query(%(up{job=~"#{net['snmp_job'] || 'snmp.*'}"}))
            uptime = vm.query("sysUpTime / 100")
            targets = (devices.map { |d| d["instance"] } + probe.map { |p| p["labels"]["instance"] }).compact.uniq
            targets.map do |inst|
              d = devices.find { |x| x["instance"] == inst } || {}
              pick = ->(arr) { arr.find { |x| x["labels"]["instance"] == inst }&.dig("value") }
              {
                name: d["name"] || inst, instance: inst, role: d["role"],
                ping_ok: pick.(probe)&.then { |v| v == 1.0 },
                rtt_ms: pick.(rtt)&.then { |v| (v * 1000).round(2) },
                snmp_ok: pick.(snmp)&.then { |v| v == 1.0 },
                uptime_hours: pick.(uptime)&.then { |v| (v / 3600).round(1) }
              }
            end
          end,

          tool("interface_status", "機器のインターフェースごとの状態・トラフィック(bps)・エラー/破棄レートを返す",
               { device: str("機器名またはinstance"),
                 only_problems: bool("trueならダウン・エラー・高使用率のポートだけ返す(既定true)") },
               required: %w[device]) do |i, _r|
            inst = find_device.(i["device"])["instance"]
            sel = %(instance="#{inst.to_s.gsub('"', '')}")
            q = {
              oper: "ifOperStatus{#{sel}}", admin: "ifAdminStatus{#{sel}}",
              in_bps: "rate(ifHCInOctets{#{sel}}[5m])*8", out_bps: "rate(ifHCOutOctets{#{sel}}[5m])*8",
              err: "rate(ifInErrors{#{sel}}[5m]) + rate(ifOutErrors{#{sel}}[5m])",
              disc: "rate(ifInDiscards{#{sel}}[5m]) + rate(ifOutDiscards{#{sel}}[5m])",
              speed: "ifHighSpeed{#{sel}}", flap: "changes(ifOperStatus{#{sel}}[30m])"
            }.transform_values { |pq| vm.query(pq) }
            key = ->(l) { l["ifName"] || l["ifDescr"] || l["ifIndex"] }
            ports = q[:oper].map { |r| key.(r["labels"]) }.uniq
            val = ->(k, port) { q[k].find { |r| key.(r["labels"]) == port }&.dig("value") }
            rows = ports.map do |p|
              speed = val.(:speed, p).to_f
              inb = val.(:in_bps, p).to_f
              outb = val.(:out_bps, p).to_f
              {
                port: p, oper_up: val.(:oper, p) == 1.0, admin_up: val.(:admin, p) == 1.0,
                in_mbps: (inb / 1e6).round(2), out_mbps: (outb / 1e6).round(2),
                util: speed.positive? ? ([inb, outb].max / (speed * 1e6)).round(3) : nil,
                err_per_s: val.(:err, p)&.round(3), discard_per_s: val.(:disc, p)&.round(3),
                flaps_30m: val.(:flap, p)&.to_i
              }
            end
            if i.fetch("only_problems", true)
              rows = rows.select do |r|
                (r[:admin_up] && !r[:oper_up]) || r[:err_per_s].to_f.positive? ||
                  r[:discard_per_s].to_f > 1 || r[:util].to_f > 0.7 || r[:flaps_30m].to_i.positive?
              end
            end
            { device: i["device"], instance: inst, ports_total: ports.size, ports: rows.first(60) }
          end,

          tool("query_metrics", "任意のPromQLを実行する。minutesを付けると範囲クエリで系列ごとの要約を返す",
               { promql: str("PromQL"), minutes: int("過去何分の推移を見るか(省略時は現在値)") },
               required: %w[promql]) do |i, _r|
            if i["minutes"]
              vm.query_range_summary(i["promql"], minutes: clamp_minutes(i["minutes"]))
            else
              res = vm.query(i["promql"])
              { series_total: res.size, result: res.first(50) }
            end
          end,

          tool("device_logs", "ネットワーク機器のsyslogを新しい順に返す",
               { device: str("機器名"), minutes: int("過去何分(既定30)"),
                 filter: str("追加のLogsQL条件(例: error, \"LAN2\")。省略可"), limit: int("最大件数(既定50)") },
               required: %w[device]) do |i, _r|
            d = find_device.(i["device"])
            host = (d["log_host"] || d["name"]).to_s.gsub('"', "")
            q = %(#{host_field}:"#{host}" #{i['filter']})
            vl.recent(q, minutes: clamp_minutes(i["minutes"], default: 30), limit: (i["limit"] || 50).to_i.clamp(1, 200))
              .map { |r| { time: r["_time"], msg: r["_msg"] } }
          end
        ]

        Agent.new(name: "network", label: "ネットワーク", model: config.dig(:claude, :subagent_model),
                  system: system, tools: tools, client: client, bus: bus,
                  max_turns: config.dig(:claude, :subagent_max_turns, default: 8))
      end
    end
  end
end
