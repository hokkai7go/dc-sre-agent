#!/usr/bin/env ruby
# モックに対する通しテスト。mock_backends.rb と bin/sre-agent(test/config.mock.yml) を起動した状態で実行する。
# 平常 → 障害発生 → 自動調査 → 報告 → 復旧 の流れを確認する。
require "net/http"
require "json"

Encoding.default_external = Encoding::UTF_8
AGENT = URI("http://127.0.0.1:8088")
MOCK = URI("http://127.0.0.1:9900")

def get(base, path) = JSON.parse(Net::HTTP.get(URI.join(base, path)))
def state = get(AGENT, "/api/state")

def wait_until(label, timeout: 120)
  t = Time.now
  until (v = yield)
    raise "タイムアウト: #{label}" if Time.now - t > timeout

    sleep 1
  end
  puts "OK  #{label} (#{(Time.now - t).round}秒)"
  v
end

failures = []
check = ->(label, cond) { cond ? puts("OK  #{label}") : (failures << label; puts("NG  #{label}")) }

wait_until("初回チェック完了") { state.dig("snapshot", "at") }
first = wait_until("平常時の注意(ストレージ)が調査される") do
  state["incidents"].find { |i| i["title"].include?("ストレージ") && i.dig("investigations", -1, "status") == "done" }
end

# 平常時のインシデントに障害がまとめられないよう、まとめる時間幅を過ぎてから障害を起こす
wait_until("まとめる時間幅(1分)の経過", timeout: 90) { Time.now - Time.parse(first["opened_at"]) > 65 }
get(MOCK, "/mock/outage?on=1")

wait_until("障害が別インシデントとして調査・報告される") do
  state["incidents"].find { |i| i["id"] != first["id"] && i.dig("investigations", -1, "status") == "done" }
end
# 障害の切り替わりがチェック周期の途中だと、最初は「注意」止まりのことがある。
# 次の周期で「重大」に上がり、待ち時間を無視して再調査されるところまで待つ。
outage = wait_until("重大に上がり、再調査まで完了する") do
  state["incidents"].find do |i|
    i["id"] != first["id"] && i["severity"] == "critical" &&
      i["investigations"].size >= 1 && i.dig("investigations", -1, "status") == "done" &&
      Time.parse(i.dig("investigations", -1, "started_at")) >= Time.parse(i["signals"].values.map { |x| x["first_seen"] }.max)
  end
end
s = state
check.("障害インシデントは重大", outage["severity"] == "critical")
check.("ストレージ警告に障害が混ざっていない", s["incidents"].find { |i| i["id"] == first["id"] }["signals"].size == 1)
report = outage.dig("investigations", -1, "report")
check.("報告に事実と推奨手順がある", report["findings"].any? && report["recommended_actions"].any?)
starts = s["activity"].select { |e| e["type"] == "agent.start" }.map { |e| e["data"] }
orch = starts.reverse.find { |d| d["agent"] == "orchestrator" && d["incident_id"] == outage["id"] }
kids = starts.select { |d| d["parent_run"] == orch["run_id"] }.map { |d| d["agent"] }.sort
check.("統括から3担当へ依頼している", kids == %w[logs network proxmox])
check.("エラーイベントが出ていない", s["activity"].none? { |e| e["type"] =~ /error/ })

get(MOCK, "/mock/outage?on=0")
wait_until("障害の復旧を検知する", timeout: 60) do
  state["incidents"].find { |i| i["id"] == outage["id"] }["status"] == "resolved"
end

req = Net::HTTP::Post.new(URI.join(AGENT, "/api/ask"), "content-type" => "application/json", "x-requested-with" => "sre-dashboard")
req.body = JSON.generate(question: "pve02のストレージはあとどれくらい持ちそう？")
ask = JSON.parse(Net::HTTP.start(AGENT.host, AGENT.port) { |h| h.request(req) }.body)
wait_until("質問に回答が返る") { get(AGENT, "/api/incidents/#{ask['id']}")["status"] == "answered" }

puts "Claude API 呼び出し回数: #{get(MOCK, '/mock/stats')['claude_calls']}"
puts failures.empty? ? "\nすべて通過" : "\n失敗: #{failures.join(', ')}"
exit(failures.empty? ? 0 : 1)
