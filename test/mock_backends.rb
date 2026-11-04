#!/usr/bin/env ruby
Encoding.default_external = Encoding::UTF_8
# 動作確認用のモック。VictoriaMetrics / VictoriaLogs / Proxmox API / Claude API を1つのポートで偽装する。
#   ruby test/mock_backends.rb 9900
#   障害を起こす:   curl localhost:9900/mock/outage?on=1
#   復旧させる:     curl localhost:9900/mock/outage?on=0
require "socket"
require "json"
require "uri"
require "time"

PORT = (ARGV[0] || 9900).to_i
$outage = false
$claude_calls = 0

def vm_result(rows) = { status: "success", data: { resultType: "vector", result: rows.map { |l, v| { metric: l, value: [Time.now.to_i, v.to_s] } } } }

DEVICES = { "192.168.101.1" => 0.0021, "192.168.101.2" => 0.0009, "192.168.101.11" => 0.0012 }.freeze

def vm_query(q)
  rows =
    case q
    when /probe_success/ then DEVICES.keys.map { |i| [{ instance: i, job: "blackbox-icmp" }, $outage && i == "192.168.101.2" ? 0 : 1] }
    when /probe_duration/ then DEVICES.map { |i, v| [{ instance: i }, v] }
    when /\Aup\{/ then DEVICES.keys.first(2).map { |i| [{ instance: i, job: "snmp" }, $outage && i == "192.168.101.2" ? 0 : 1] }
    when /sysUpTime/ then DEVICES.keys.first(2).map { |i| [{ instance: i }, 86_400_00 * 31] }
    when /changes\(ifOperStatus\[10m\]\)/ then $outage ? [[{ instance: "192.168.101.1", ifName: "LAN1.3" }, 4]] : []
    when /ifInErrors\[5m\]\) \+ rate\(ifOutErrors\[5m\]\)\) >/ then []
    when /ifOperStatus\{/ then %w[LAN1 LAN1.3 LAN2].map { |p| [{ instance: "192.168.101.1", ifName: p }, $outage && p == "LAN1.3" ? 2 : 1] }
    when /ifAdminStatus\{/ then %w[LAN1 LAN1.3 LAN2].map { |p| [{ instance: "192.168.101.1", ifName: p }, 1] }
    when /changes\(ifOperStatus/ then $outage ? [[{ instance: "192.168.101.1", ifName: "LAN1.3" }, 4]] : []
    when /ifHighSpeed\{/ then %w[LAN1 LAN1.3 LAN2].map { |p| [{ instance: "192.168.101.1", ifName: p }, 1000] }
    when /ifHCInOctets\{/ then [[{ instance: "192.168.101.1", ifName: "LAN2" }, 3_200_000]]
    else []
    end
  vm_result(rows)
end

def logs(q)
  if q.include?("stats by (hostname)")
    if q.include?("severity")
      rows = [{ hostname: "pve01", n: 3 }]
      rows << { hostname: "rtx1300", n: 42 } if $outage
    elsif q.include?("Rejected")
      rows = [{ hostname: "rtx1300", n: $outage ? 12 : 4 }]
    elsif q.include?("login")
      rows = []
    else
      rows = [{ hostname: "rtx1300", n: 1840 }, { hostname: "pve01", n: 512 }, { hostname: "pve02", n: 488 }, { hostname: "core-sw01", n: $outage ? 0 : 96 }]
    end
    return rows.map { |r| JSON.generate(r.transform_values(&:to_s)) }.join("\n")
  end
  if q.include?("stats by (_time")
    return (0..5).map { |i| JSON.generate(_time: (Time.now - (5 - i) * 300).utc.iso8601, n: ($outage && i > 3 ? 40 : 2).to_s) }.join("\n")
  end
  lines = [
    { _time: Time.now.utc.iso8601, hostname: "rtx1300", app_name: "", severity: "err", _msg: "LAN1.3: link down" },
    { _time: (Time.now - 20).utc.iso8601, hostname: "rtx1300", app_name: "", severity: "err", _msg: "[BGP] neighbor 192.168.1.1 state changed Established -> Idle" },
    { _time: (Time.now - 600).utc.iso8601, hostname: "pve01", app_name: "pvedaemon", severity: "err", _msg: "VM 104 qmp command failed - got timeout" }
  ]
  lines = lines.last(1) unless $outage
  lines.map { |l| JSON.generate(l) }.join("\n")
end

def pve(path)
  data =
    case path
    when %r{/cluster/resources} then [
      { type: "node", node: "pve01", status: "online", cpu: 0.21, mem: 48e9, maxmem: 128e9, uptime: 3_000_000 },
      { type: "node", node: "pve02", status: "online", cpu: 0.64, mem: 101e9, maxmem: 128e9, uptime: 3_000_000 },
      { type: "qemu", vmid: 100, name: "traefik", node: "pve01", status: "running", cpu: 0.02, mem: 1e9, maxmem: 2e9 },
      { type: "qemu", vmid: 101, name: "victoria", node: "pve01", status: "running", cpu: 0.11, mem: 6e9, maxmem: 8e9 },
      { type: "qemu", vmid: 104, name: "phpipam", node: "pve02", status: "running", cpu: 0.01, mem: 1e9, maxmem: 2e9 },
      { type: "lxc", vmid: 200, name: "powerdns", node: "pve02", status: "running", cpu: 0.01, mem: 2e8, maxmem: 1e9 },
      { type: "qemu", vmid: 110, name: "test-old", node: "pve02", status: "stopped", cpu: 0, mem: 0, maxmem: 4e9 },
      { type: "storage", node: "pve01", storage: "local-zfs", disk: 610e9, maxdisk: 900e9, shared: 0 },
      { type: "storage", node: "pve02", storage: "local-zfs", disk: 790e9, maxdisk: 900e9, shared: 0 },
      { type: "storage", node: "pve01", storage: "nas-backup", disk: 3.1e12, maxdisk: 8e12, shared: 1 },
      { type: "storage", node: "pve02", storage: "nas-backup", disk: 3.1e12, maxdisk: 8e12, shared: 1 }
    ]
    when %r{/cluster/tasks} then [{ upid: "UPID:pve02:1", type: "vzdump", id: "104", node: "pve02", user: "root@pam", status: "OK", starttime: Time.now.to_i - 7200, endtime: Time.now.to_i - 7000 }]
    when %r{/nodes/\w+/status} then { cpu: 0.2, loadavg: %w[1.2 1.1 0.9], cpuinfo: { cpus: 16 }, memory: { used: 48e9, total: 128e9 }, swap: { used: 0, total: 8e9 }, rootfs: { used: 20e9, total: 100e9 }, uptime: 3_000_000, kversion: "Linux 6.8", pveversion: "pve-manager/8.4" }
    when /rrddata/ then (0..10).map { |i| { time: Time.now.to_i - i * 60, cpu: 0.2 + i * 0.01, memused: 48e9 } }
    when %r{/storage} then [{ storage: "local-zfs", type: "zfspool", active: 1, enabled: 1, used: 610e9, total: 900e9, avail: 290e9 }]
    else {}
    end
  { data: data }
end

def claude(body)
  $claude_calls += 1
  sleep 0.7
  tools = (body["tools"] || []).map { |t| t["name"] }
  msgs = body["messages"]
  turn = msgs.count { |m| m["role"] == "assistant" }
  last_results = msgs.last["content"].is_a?(Array) ? msgs.last["content"].map { |c| c["content"] }.join("\n") : ""
  content =
    if tools.include?("ask_network_agent")
      case turn
      when 0 then [{ type: "text", text: "定期監視の全体状況を先に確認します。" }, tu("current_snapshot", {})]
      when 1 then [{ type: "text", text: "コアスイッチの疎通断とrtx1300のリンク変化が同時に出ています。3担当に並行して確認します。" },
                   tu("ask_network_agent", { question: "core-sw01(192.168.101.2)への疎通が失敗しています。rtx1300 LAN1.3のリンク状態変化との関係を、インターフェース状態と機器ログで確認してください。" }),
                   tu("ask_proxmox_agent", { question: "直近15分でpve01/pve02からcore-sw01配下への影響(ノード状態、VMの異常、タスク失敗)がないか確認してください。" }),
                   tu("ask_logs_agent", { question: "直近30分のrtx1300とcore-sw01のログで、リンクダウン・BGP状態変化の時刻と件数を調べてください。" })]
      else [tu("submit_report", {
        severity: "critical", title: "core-sw01への疎通断(rtx1300 LAN1.3 リンクダウン)",
        summary: "rtx1300のLAN1.3が繰り返しリンクダウンし、その先のcore-sw01へ疎通できない状態です。同時刻に自宅とのBGPもIdleに落ちています。Proxmoxノードと主要VMは稼働しています。まずLAN1.3の物理配線とcore-sw01の電源を確認してください。",
        findings: ["rtx1300 LAN1.3 の ifOperStatus が過去10分で4回変化", "core-sw01 の ICMP と SNMP がともに失敗", "rtx1300 syslog に link down と BGP Established -> Idle", "pve01/pve02 はオンライン、ゲスト停止はtest-old(既知)のみ"],
        probable_cause: "推測: LAN1.3 のケーブルまたはSFP不良、もしくはcore-sw01側の再起動。ログだけでは区別できない",
        impact: "core-sw01配下のセグメントと、自宅⇔職場のIPsec+BGP経路が使えない可能性",
        recommended_actions: ["現地でLAN1.3のリンクランプとcore-sw01の電源・コンソールを確認", "core-sw01が起動していればLAN1.3側のケーブル・SFPを交換", "復旧後にBGPがEstablishedに戻ったことをrtx1300で確認"],
        confidence: "medium" })]
      end
    elsif turn.zero?
      first = { "list_devices" => {}, "cluster_overview" => {}, "search_logs" => { query: "error", minutes: 30 } }
      name = tools.find { |t| first.key?(t) }
      [tu(name, first[name])]
    else
      [{ type: "text", text: "結論: 確認しました(モック応答)。\n確認した事実: #{last_results.gsub(/\s+/, ' ')[0, 160]}…" }]
    end
  stop = content.any? { |c| c[:type] == "tool_use" } ? "tool_use" : "end_turn"
  { id: "msg_mock", type: "message", role: "assistant", content: content, stop_reason: stop,
    usage: { input_tokens: 1200, output_tokens: 180, cache_read_input_tokens: 900 } }
end

def tu(name, input) = { type: "tool_use", id: "toolu_#{rand(36**8).to_s(36)}", name: name, input: input }

server = TCPServer.new("127.0.0.1", PORT)
warn "mock on #{PORT}"
loop do
  Thread.new(server.accept) do |s|
    line = s.gets("\r\n").to_s
    method, target = line.split(" ")
    h = {}
    while (l = s.gets("\r\n")) && l != "\r\n"
      k, v = l.split(":", 2)
      h[k.downcase] = v.strip
    end
    body = h["content-length"].to_i.positive? ? s.read(h["content-length"].to_i) : ""
    path, qs = target.to_s.split("?", 2)
    params = URI.decode_www_form(qs.to_s).to_h
    out =
      case path
      when "/mock/outage" then $outage = params["on"] == "1"; JSON.generate(outage: $outage)
      when "/mock/stats" then JSON.generate(claude_calls: $claude_calls)
      when "/api/v1/query" then JSON.generate(vm_query(params["query"]))
      when "/api/v1/query_range" then JSON.generate(status: "success", data: { result: [] })
      when "/select/logsql/query" then logs(params["query"])
      when %r{\A/api2/json} then JSON.generate(pve(path))
      when "/v1/messages" then JSON.generate(claude(JSON.parse(body)))
      else JSON.generate(error: "unknown #{path}")
      end
    s.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\nConnection: close\r\n\r\n#{out}")
  rescue StandardError => e
    warn "mock error: #{e.full_message}"
  ensure
    s.close
  end
end
