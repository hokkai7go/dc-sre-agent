module SreAgent
  module Agents
    # Proxmox担当サブエージェント。Proxmox VE API を PVEAuditor 権限で読む。
    module ProxmoxAgent
      extend ToolHelpers
      module_function

      def build(config:, pve:, vl:, client:, bus:)
        critical = Array(config.dig(:watch, :proxmox, :critical_vms, default: []))
        host_field = config.dig(:watch, :logs, :host_field, default: "hostname")

        system = <<~TXT
          あなたは#{config.site}のProxmox VE担当SREです。統括エージェントからの依頼に答えます。
          常時稼働が必要なVM/CT: #{critical.empty? ? '(指定なし)' : critical.join(', ')}

          調べ方の目安: cluster_overview で全体像(ノード・VM・ストレージ)をつかみ、
          怪しいノードやVMを node_detail / vm_detail / performance_history で掘り下げます。
          バックアップやマイグレーションの失敗は recent_tasks、ノードのOSログは node_logs で見ます。
          cpu は0〜1の比率、mem/disk はバイトです。人に伝えるときは%やGiBに直してください。

          #{ToolHelpers::COMMON_RULES}
        TXT

        gib = ->(b) { b ? (b.to_f / 1024**3).round(1) : nil }
        pct = ->(a, b) { b.to_f.positive? ? (a.to_f / b.to_f * 100).round(1) : nil }

        tools = [
          tool("cluster_overview", "クラスタのノード・VM/CT・ストレージの現状を要約して返す") do |_i, _r|
            res = pve.resources
            nodes = res.select { |r| r["type"] == "node" }.map do |n|
              { node: n["node"], status: n["status"], cpu_pct: (n["cpu"].to_f * 100).round(1),
                mem_pct: pct.(n["mem"], n["maxmem"]), uptime_h: (n["uptime"].to_i / 3600.0).round(1) }
            end
            guests = res.select { |r| %w[qemu lxc].include?(r["type"]) }
            storages = res.select { |r| r["type"] == "storage" }.map do |s|
              { node: s["node"], storage: s["storage"], status: s["status"],
                used_pct: pct.(s["disk"], s["maxdisk"]), free_gib: gib.(s["maxdisk"].to_i - s["disk"].to_i) }
            end
            {
              nodes: nodes,
              guests_summary: guests.group_by { |g| g["status"] }.transform_values(&:size),
              guests_not_running: guests.reject { |g| g["status"] == "running" }
                                        .map { |g| { vmid: g["vmid"], name: g["name"], node: g["node"], type: g["type"], status: g["status"] } }.first(40),
              busiest_guests: guests.select { |g| g["status"] == "running" }.sort_by { |g| -g["cpu"].to_f }.first(10)
                                    .map { |g| { vmid: g["vmid"], name: g["name"], node: g["node"], cpu_pct: (g["cpu"].to_f * 100).round(1), mem_pct: pct.(g["mem"], g["maxmem"]) } },
              storages: storages
            }
          end,

          tool("node_detail", "ノードの詳細(負荷平均・CPU・メモリ・swap・rootfs・カーネル)を返す",
               { node: str("ノード名") }, required: %w[node]) do |i, _r|
            s = pve.node_status(i["node"])
            {
              node: i["node"], loadavg: s["loadavg"], cpu_pct: (s["cpu"].to_f * 100).round(1), cpus: s.dig("cpuinfo", "cpus"),
              mem_pct: pct.(s.dig("memory", "used"), s.dig("memory", "total")),
              swap_pct: pct.(s.dig("swap", "used"), s.dig("swap", "total")),
              rootfs_pct: pct.(s.dig("rootfs", "used"), s.dig("rootfs", "total")),
              wait: s["wait"], uptime_h: (s["uptime"].to_i / 3600.0).round(1), kernel: s["kversion"], pve: s["pveversion"]
            }
          end,

          tool("vm_detail", "VM/CTの現在状態を返す",
               { node: str("ノード名"), vmid: int("VMID"), type: str("qemu か lxc", enum: %w[qemu lxc]) },
               required: %w[node vmid]) do |i, _r|
            s = pve.vm_status(i["node"], i["vmid"], kind: i["type"] || "qemu")
            s.slice("vmid", "name", "status", "qmpstatus", "lock", "ha", "uptime", "cpus", "pid", "agent")
             .merge("cpu_pct" => (s["cpu"].to_f * 100).round(1), "mem_pct" => pct.(s["mem"], s["maxmem"]),
                    "disk_read_gib" => gib.(s["diskread"]), "disk_write_gib" => gib.(s["diskwrite"]))
          end,

          tool("performance_history", "ノードまたはVMの性能履歴(RRD)を項目ごとの最小/最大/平均/最新で返す",
               { node: str("ノード名"), vmid: int("VMID(省略するとノード自体)"),
                 type: str("qemu か lxc", enum: %w[qemu lxc]), timeframe: str("hour/day/week", enum: %w[hour day week]) },
               required: %w[node]) do |i, _r|
            rows = pve.rrd(i["node"], vmid: i["vmid"], kind: i["type"] || "qemu", timeframe: i["timeframe"] || "hour")
            { points: Array(rows).size, summary: summarize_rows(rows) }
          end,

          tool("recent_tasks", "クラスタの最近のタスク(バックアップ、マイグレーション等)を返す",
               { errors_only: bool("失敗したタスクだけにする(既定true)"), limit: int("件数(既定30)") }) do |i, _r|
            pve.tasks(limit: (i["limit"] || 30).to_i.clamp(1, 100), errors: i.fetch("errors_only", true)).map do |t|
              { type: t["type"], id: t["id"], node: t["node"], user: t["user"], status: t["status"],
                start: Time.at(t["starttime"].to_i).getlocal("+09:00").strftime("%m-%d %H:%M"),
                end: t["endtime"] ? Time.at(t["endtime"].to_i).getlocal("+09:00").strftime("%m-%d %H:%M") : nil }
            end
          end,

          tool("storage_status", "ノードから見えるストレージの使用率と状態を返す",
               { node: str("ノード名") }, required: %w[node]) do |i, _r|
            pve.storage(i["node"]).map do |s|
              { storage: s["storage"], type: s["type"], active: s["active"] == 1, enabled: s["enabled"] != 0,
                used_pct: pct.(s["used"], s["total"]), avail_gib: gib.(s["avail"]) }
            end
          end,

          tool("node_logs", "ProxmoxノードのOSログ(syslog/journal)をログ基盤から新しい順に返す",
               { node: str("ノード名"), minutes: int("過去何分(既定30)"), filter: str("追加のLogsQL条件。省略可") },
               required: %w[node]) do |i, _r|
            q = %(#{host_field}:"#{i['node'].to_s.gsub('"', '')}" #{i['filter']})
            vl.recent(q, minutes: clamp_minutes(i["minutes"], default: 30), limit: 60)
              .map { |r| { time: r["_time"], app: r["app_name"], msg: r["_msg"] } }
          end
        ]

        Agent.new(name: "proxmox", label: "Proxmox", model: config.dig(:claude, :subagent_model),
                  system: system, tools: tools, client: client, bus: bus,
                  max_turns: config.dig(:claude, :subagent_max_turns, default: 8))
      end
    end
  end
end
