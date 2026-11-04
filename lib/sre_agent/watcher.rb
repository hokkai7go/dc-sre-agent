require "time"

module SreAgent
  # 定期チェックを回し、インシデントの発生・更新・復旧を判定して、必要なときだけ統括エージェントを起動する。
  class Watcher
    attr_reader :snapshot

    def initialize(config:, checks:, store:, bus:, orchestrator:)
      @config = config
      @checks = checks
      @store = store
      @bus = bus
      @orchestrator = orchestrator
      @interval = config.dig(:watch, :interval_seconds, default: 60).to_i
      @cooldown = config.dig(:claude, :cooldown_minutes, default: 15).to_i * 60
      @daily_limit = config.dig(:claude, :daily_investigation_limit, default: 30).to_i
      @min_severity = config.dig(:claude, :investigate_min_severity, default: "warning")
      @auto = config.dig(:claude, :auto_investigate, default: true)
      @snapshot = { "at" => nil }
      @jobs = Queue.new
      @daily = { date: nil, count: 0 }
      @last_investigated = {}
    end

    def start
      @loop = Thread.new { loop_forever }
      @worker = Thread.new { work_forever } if @orchestrator
      self
    end

    def llm_enabled? = !@orchestrator.nil?

    def enqueue_inquiry(question)
      raise "Claude APIキーが未設定のため、質問機能は使えません" unless @orchestrator

      inc = @store.create_inquiry(question)
      @bus.emit("incident.opened", incident: inc)
      @jobs << [:inquiry, inc["id"]]
      inc
    end

    def enqueue_investigation(id)
      raise "Claude APIキーが未設定のため、調査機能は使えません" unless @orchestrator

      @jobs << [:investigate, id, true]
    end

    def status
      {
        llm_enabled: llm_enabled?, auto_investigate: @auto, interval_seconds: @interval,
        investigations_today: @daily[:count], daily_limit: @daily_limit, queue: @jobs.size
      }
    end

    def run_once
      started = Time.now
      results = @checks.transform_values { |c| Thread.new { c.run } }.transform_values(&:value)
      signals = results.values.flat_map { |r| r[:signals] }
      changes = @store.reconcile(signals)

      @snapshot = JSON.parse(JSON.generate({
        "at" => Time.now.utc.iso8601, "took_ms" => ((Time.now - started) * 1000).round,
        "network" => results[:network]&.dig(:state), "proxmox" => results[:proxmox]&.dig(:state),
        "logs" => results[:logs]&.dig(:state), "signals" => @store.active_signals, "agent" => status
      }))
      @bus.emit("snapshot", snapshot: @snapshot)

      changes[:opened].each { |i| @bus.emit("incident.opened", incident: i) }
      changes[:updated].each { |i| @bus.emit("incident.updated", incident: i) }
      changes[:resolved].each { |i| @bus.emit("incident.resolved", incident: i) }
      schedule(changes[:opened] + changes[:updated]) if @orchestrator && @auto
    end

    private

    def loop_forever
      loop do
        begin
          run_once
        rescue StandardError => e
          @bus.emit("watcher.error", error: "#{e.class}: #{e.message}")
          warn e.full_message
        end
        sleep @interval
      end
    end

    def schedule(incidents)
      incidents.each do |inc|
        next unless inc["new_signals_since_investigation"]
        sev = IncidentStore::SEV[inc["severity"]].to_i
        next if sev < IncidentStore::SEV[@min_severity].to_i

        # 前回調査より重大度が上がったときは、待ち時間を無視して調べ直す
        last = @last_investigated[inc["id"]]
        next if last && Time.now - last[:at] < @cooldown && sev <= last[:sev]

        @last_investigated[inc["id"]] = { at: Time.now, sev: sev }
        @jobs << [:investigate, inc["id"], false]
      end
    end

    def work_forever
      loop do
        kind, id, manual = @jobs.pop
        today = Time.now.getlocal("+09:00").strftime("%F")
        @daily = { date: today, count: 0 } if @daily[:date] != today
        if !manual && kind == :investigate && @daily[:count] >= @daily_limit
          @bus.emit("agent.skipped", incident_id: id, reason: "本日の自動調査上限(#{@daily_limit}件)に達しました")
          next
        end
        @daily[:count] += 1
        inc = @store.start_investigation(id) or next
        @bus.emit("incident.investigating", incident: inc)
        result = kind == :inquiry ? @orchestrator.ask(inc["question"]) : @orchestrator.investigate(inc)
        done = @store.finish_investigation(id, **result)
        @bus.emit("incident.report", incident: done)
      rescue StandardError => e
        @bus.emit("watcher.error", error: "調査ワーカー: #{e.class}: #{e.message}")
        warn e.full_message
      end
    end
  end
end
