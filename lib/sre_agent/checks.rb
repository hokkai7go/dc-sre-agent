module SreAgent
  # LLMを使わない定期チェック。しきい値判定だけで「シグナル」を出し、ダッシュボード用の状態も集める。
  # Claude を呼ぶのはシグナルが新しくインシデントになったときだけなので、平常時はAPI費用がかからない。
  module Checks
    Signal = Struct.new(:key, :source, :severity, :title, :detail, keyword_init: true) do
      def to_h = { "key" => key, "source" => source, "severity" => severity, "title" => title, "detail" => detail }
    end

    def self.source_error(source, label, err)
      Signal.new(key: "#{source}:source_unreachable", source: source, severity: "warning",
                 title: "#{label}から監視データを取得できない", detail: err.message[0, 200])
    end

    class Network
      def initialize(config:, vm:)
        @c = config.dig(:watch, :network, default: {})
        @vm = vm
        @devices = Array(@c["devices"])
      end

      def run
        signals = []
        ping_job = @c["ping_job"] || "blackbox-icmp"
        probe = @vm.query(%(probe_success{job=~"#{ping_job}"}))
        rtt = @vm.query(%(probe_duration_seconds{job=~"#{ping_job}"}))
        snmp = @vm.query(%(up{job=~"#{@c['snmp_job'] || 'snmp.*'}"}))

        targets = (@devices.map { |d| d["instance"] } + probe.map { |p| p["labels"]["instance"] }).compact.uniq
        rows = targets.map do |inst|
          d = @devices.find { |x| x["instance"] == inst } || {}
          name = d["name"] || inst
          p = probe.find { |x| x["labels"]["instance"] == inst }
          s = snmp.find { |x| x["labels"]["instance"] == inst }
          r = rtt.find { |x| x["labels"]["instance"] == inst }
          ok = p && p["value"] == 1.0
          if p && !ok
            signals << Signal.new(key: "net:down:#{inst}", source: "network", severity: d["critical"] == false ? "warning" : "critical",
                                  title: "#{name} へ疎通なし", detail: "ICMP probe_success=0 (#{inst})")
          elsif p.nil? && !d.empty?
            signals << Signal.new(key: "net:noprobe:#{inst}", source: "network", severity: "warning",
                                  title: "#{name} の疎通データなし", detail: "probe_success の系列がありません。blackbox の設定を確認")
          end
          if s && s["value"] != 1.0
            signals << Signal.new(key: "net:snmp:#{inst}", source: "network", severity: "warning",
                                  title: "#{name} のSNMP取得失敗", detail: "up=0 (#{inst})")
          end
          { name: name, instance: inst, role: d["role"], ping: p ? ok : nil, snmp: s ? s["value"] == 1.0 : nil,
            rtt_ms: r ? (r["value"] * 1000).round(2) : nil }
        end

        err_thr = (@c["if_error_rate_threshold"] || 1).to_f
        @vm.query("(rate(ifInErrors[5m]) + rate(ifOutErrors[5m])) > #{err_thr}").each do |e|
          l = e["labels"]
          signals << Signal.new(key: "net:iferr:#{l['instance']}:#{l['ifName'] || l['ifIndex']}", source: "network", severity: "warning",
                                title: "#{dev_name(l['instance'])} #{l['ifName'] || l['ifIndex']} でエラー増加",
                                detail: "#{e['value'].round(2)} errors/s (しきい値 #{err_thr})")
        end
        @vm.query("changes(ifOperStatus[10m]) > 0").each do |e|
          l = e["labels"]
          signals << Signal.new(key: "net:flap:#{l['instance']}:#{l['ifName'] || l['ifIndex']}", source: "network", severity: "warning",
                                title: "#{dev_name(l['instance'])} #{l['ifName'] || l['ifIndex']} のリンク状態変化",
                                detail: "過去10分で#{e['value'].to_i}回変化")
        end
        util_thr = (@c["if_util_threshold"] || 0.9).to_f
        util_q = <<~Q.tr("\n", " ")
          max by (instance, ifName) (
            label_replace(rate(ifHCInOctets[5m])*8 / ((ifHighSpeed > 0)*1000000), "dir", "in", "", "")
            or label_replace(rate(ifHCOutOctets[5m])*8 / ((ifHighSpeed > 0)*1000000), "dir", "out", "", "")
          ) > #{util_thr}
        Q
        @vm.query(util_q).each do |e|
          l = e["labels"]
          signals << Signal.new(key: "net:util:#{l['instance']}:#{l['ifName']}", source: "network", severity: "warning",
                                title: "#{dev_name(l['instance'])} #{l['ifName']} の帯域逼迫",
                                detail: "使用率 #{(e['value'] * 100).round(1)}%")
        end
        { signals: signals, state: { devices: rows } }
      rescue Sources::SourceError => e
        { signals: [Checks.source_error("network", "VictoriaMetrics", e)], state: { devices: [], error: e.message } }
      end

      private

      def dev_name(inst) = @devices.find { |d| d["instance"] == inst }&.dig("name") || inst
    end

    class Proxmox
      def initialize(config:, pve:)
        @c = config.dig(:watch, :proxmox, default: {})
        @pve = pve
        @seen_tasks = {}
      end

      def run
        signals = []
        res = @pve.resources
        cpu_thr = (@c["cpu_threshold"] || 0.9).to_f
        mem_thr = (@c["mem_threshold"] || 0.9).to_f
        sto_thr = (@c["storage_threshold"] || 0.85).to_f

        nodes = res.select { |r| r["type"] == "node" }.map do |n|
          mem = n["maxmem"].to_f.positive? ? n["mem"].to_f / n["maxmem"].to_f : nil
          if n["status"] != "online"
            signals << Signal.new(key: "pve:node:#{n['node']}", source: "proxmox", severity: "critical",
                                  title: "ノード #{n['node']} がオフライン", detail: "status=#{n['status']}")
          else
            if n["cpu"].to_f > cpu_thr
              signals << Signal.new(key: "pve:cpu:#{n['node']}", source: "proxmox", severity: "warning",
                                    title: "ノード #{n['node']} のCPU高負荷", detail: "#{(n['cpu'].to_f * 100).round(1)}%")
            end
            if mem && mem > mem_thr
              signals << Signal.new(key: "pve:mem:#{n['node']}", source: "proxmox", severity: "warning",
                                    title: "ノード #{n['node']} のメモリ逼迫", detail: "#{(mem * 100).round(1)}%")
            end
          end
          { node: n["node"], status: n["status"], cpu: n["cpu"].to_f.round(3), mem: mem&.round(3), uptime: n["uptime"].to_i }
        end

        storages = res.select { |r| r["type"] == "storage" && r["maxdisk"].to_f.positive? }.map do |s|
          used = s["disk"].to_f / s["maxdisk"].to_f
          if used > sto_thr
            signals << Signal.new(key: "pve:storage:#{s['node']}:#{s['storage']}", source: "proxmox",
                                  severity: used > 0.95 ? "critical" : "warning",
                                  title: "ストレージ #{s['storage']}(#{s['node']}) の残量不足", detail: "使用率 #{(used * 100).round(1)}%")
          end
          { node: s["node"], storage: s["storage"], used: used.round(3), shared: s["shared"] == 1 }
        end
        storages = storages.uniq { |s| s[:shared] ? s[:storage] : "#{s[:node]}/#{s[:storage]}" }

        guests = res.select { |r| %w[qemu lxc].include?(r["type"]) }
        Array(@c["critical_vms"]).each do |vmid|
          g = guests.find { |x| x["vmid"].to_i == vmid.to_i }
          next if g && g["status"] == "running"

          signals << Signal.new(key: "pve:vm:#{vmid}", source: "proxmox", severity: "critical",
                                title: "重要VM #{vmid}#{g ? " (#{g['name']})" : ''} が停止",
                                detail: g ? "status=#{g['status']} node=#{g['node']}" : "クラスタ上に見つかりません")
        end

        window = (@c["task_failure_window_minutes"] || 60).to_i * 60
        failed = @pve.tasks(limit: 200, errors: true).select { |t| Time.now.to_i - t["starttime"].to_i < window }
        failed.each do |t|
          signals << Signal.new(key: "pve:task:#{t['upid']}", source: "proxmox", severity: "warning",
                                title: "#{t['node']} のタスク失敗: #{t['type']} #{t['id']}", detail: t["status"].to_s[0, 200])
        end

        {
          signals: signals,
          state: {
            nodes: nodes, storages: storages,
            guests: { running: guests.count { |g| g["status"] == "running" }, total: guests.size,
                      stopped: guests.reject { |g| g["status"] == "running" }.map { |g| "#{g['vmid']} #{g['name']}" }.first(20) },
            failed_tasks: failed.size
          }
        }
      rescue Sources::SourceError => e
        { signals: [Checks.source_error("proxmox", "Proxmox API", e).tap { |s| s.severity = "critical" }],
          state: { nodes: [], storages: [], error: e.message } }
      end
    end

    class Logs
      def initialize(config:, vl:)
        @c = config.dig(:watch, :logs, default: {})
        @vl = vl
      end

      def run
        signals = []
        window = (@c["window_minutes"] || 5).to_i
        host = @c["host_field"] || "hostname"
        err_q = @c["error_query"] || 'severity:~"^(err|crit|alert|emerg)"'
        thr = (@c["error_threshold"] || 30).to_i

        total = @vl.count_by("*", field: host, minutes: window, top: 50)
        errors = @vl.count_by(err_q, field: host, minutes: window, top: 50)
        errors.each do |r|
          next unless r["n"] >= thr

          signals << Signal.new(key: "log:errors:#{r[host]}", source: "logs", severity: "warning",
                                title: "#{r[host]} のエラーログ急増", detail: "直近#{window}分で#{r['n']}件 (しきい値 #{thr})")
        end

        security = Array(@c["security_patterns"]).map do |pat|
          hits = @vl.count_by(pat["query"], field: host, minutes: window, top: 20)
          sum = hits.sum { |h| h["n"] }
          limit = (pat["threshold"] || 10).to_i
          hits.each do |h|
            next unless h["n"] >= limit

            signals << Signal.new(key: "log:sec:#{pat['name']}:#{h[host]}", source: "logs", severity: pat["severity"] || "warning",
                                  title: "#{h[host]} で#{pat['name']}", detail: "直近#{window}分で#{h['n']}件 (しきい値 #{limit})")
          end
          { name: pat["name"], hits: sum }
        end

        recent = @vl.recent(err_q, minutes: 60, limit: 15).map do |r|
          { time: r["_time"], host: r[host], app: r["app_name"], msg: r["_msg"].to_s[0, 240] }
        end

        {
          signals: signals,
          state: {
            window_minutes: window,
            hosts: total.map { |r| { host: r[host], total: r["n"], errors: errors.find { |e| e[host] == r[host] }&.dig("n") || 0 } },
            security: security, recent_errors: recent
          }
        }
      rescue Sources::SourceError => e
        { signals: [Checks.source_error("logs", "VictoriaLogs", e)], state: { hosts: [], error: e.message } }
      end
    end
  end
end
