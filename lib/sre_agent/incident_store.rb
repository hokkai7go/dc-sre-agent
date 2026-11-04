require "json"
require "securerandom"
require "fileutils"
require "time"

module SreAgent
  # シグナルをインシデントにまとめ、復旧判定と調査結果を保持する。
  # 同じ時間帯に出たシグナルは1件のインシデントにまとめ、スイッチ1台の故障で調査が10本走るのを防ぐ。
  class IncidentStore
    SEV = { "info" => 0, "warning" => 1, "critical" => 2 }.freeze

    def initialize(dir:, group_window_minutes: 10, resolve_after_cycles: 2, keep: 300)
      @path = File.join(dir, "incidents.json")
      FileUtils.mkdir_p(dir)
      @group_window = group_window_minutes * 60
      @resolve_after = resolve_after_cycles
      @keep = keep
      @mutex = Mutex.new
      @incidents = load
    end

    def reconcile(signals)
      now = Time.now.utc
      by_key = signals.to_h { |s| [s.key, s] }
      opened = []
      updated = []
      resolved = []

      @mutex.synchronize do
        claimed = {}
        open_incidents.each do |inc|
          changed = false
          inc["signals"].each do |key, sig|
            if (s = by_key[key])
              claimed[key] = true
              changed ||= !sig["active"]
              sig.merge!("active" => true, "last_seen" => now.iso8601, "detail" => s.detail, "severity" => s.severity, "clear_cycles" => 0)
            elsif sig["active"] || sig["clear_cycles"].to_i < @resolve_after
              changed ||= sig["active"]
              sig["active"] = false
              sig["clear_cycles"] = sig["clear_cycles"].to_i + 1
            end
          end
          if inc["signals"].values.none? { |s| s["active"] } && inc["signals"].values.all? { |s| s["clear_cycles"].to_i >= @resolve_after }
            inc["status"] = "resolved"
            inc["resolved_at"] = now.iso8601
            resolved << inc
          elsif changed
            refresh(inc, now)
            updated << inc
          end
        end

        fresh = signals.reject { |s| claimed[s.key] }
        unless fresh.empty?
          # 直近に新しいシグナルが出ているインシデントにだけ相乗りさせる。
          # 長く続いている別件(ストレージ残量など)に、無関係な障害が吸い込まれないようにするため。
          latest = ->(i) { i["signals"].values.map { |s| s["first_seen"] }.max }
          target = open_incidents.select { |i| now - Time.parse(latest.(i)) < @group_window }.max_by { |i| latest.(i) }
          if target
            fresh.each { |s| target["signals"][s.key] = new_signal(s, now) }
            target["new_signals_since_investigation"] = true
            refresh(target, now)
            updated << target unless updated.include?(target)
          else
            inc = {
              "id" => "INC-#{now.getlocal('+09:00').strftime('%m%d-%H%M')}-#{SecureRandom.hex(2)}",
              "kind" => "alert", "status" => "open", "opened_at" => now.iso8601,
              "signals" => fresh.to_h { |s| [s.key, new_signal(s, now)] },
              "investigations" => [], "new_signals_since_investigation" => true
            }
            refresh(inc, now)
            @incidents[inc["id"]] = inc
            opened << inc
          end
        end
        trim
      end
      save if [opened, updated, resolved].any? { |a| !a.empty? }
      { opened: opened.map { deep(_1) }, updated: updated.map { deep(_1) }, resolved: resolved.map { deep(_1) } }
    end

    def create_inquiry(question)
      now = Time.now.utc.iso8601
      inc = { "id" => "ASK-#{SecureRandom.hex(3)}", "kind" => "inquiry", "status" => "open", "title" => question[0, 80],
              "question" => question, "opened_at" => now, "updated_at" => now, "severity" => "info",
              "signals" => {}, "investigations" => [] }
      @mutex.synchronize { @incidents[inc["id"]] = inc; trim }
      save
      deep(inc)
    end

    def start_investigation(id)
      @mutex.synchronize do
        inc = @incidents[id] or return nil
        inv = { "id" => SecureRandom.hex(3), "status" => "running", "started_at" => Time.now.utc.iso8601 }
        inc["investigations"] << inv
        inc["new_signals_since_investigation"] = false
        deep(inc)
      end
    end

    def finish_investigation(id, run_id:, report:, error:)
      @mutex.synchronize do
        inc = @incidents[id] or return nil
        inv = inc["investigations"].last
        inv.merge!("status" => error ? "failed" : "done", "finished_at" => Time.now.utc.iso8601,
                   "run_id" => run_id, "report" => report, "error" => error)
        inc["status"] = "answered" if inc["kind"] == "inquiry"
        inc["updated_at"] = Time.now.utc.iso8601
      end
      save
      get(id)
    end

    def acknowledge(id)
      @mutex.synchronize { @incidents[id]&.store("acknowledged_at", Time.now.utc.iso8601) }
      save
      get(id)
    end

    def get(id) = @mutex.synchronize { @incidents[id] && deep(@incidents[id]) }

    def list(limit: 100)
      @mutex.synchronize { @incidents.values.sort_by { |i| i["opened_at"] }.reverse.first(limit).map { deep(_1) } }
    end

    def active_signals
      @mutex.synchronize do
        open_incidents.flat_map { |i| i["signals"].values.select { |s| s["active"] }.map { |s| s.merge("incident" => i["id"]) } }
      end
    end

    private

    def open_incidents = @incidents.values.select { |i| i["kind"] == "alert" && i["status"] == "open" }

    def new_signal(s, now)
      s.to_h.merge("first_seen" => now.iso8601, "last_seen" => now.iso8601, "active" => true, "clear_cycles" => 0)
    end

    def refresh(inc, now)
      sigs = inc["signals"].values
      active = sigs.select { |s| s["active"] }
      basis = active.empty? ? sigs : active
      top = basis.max_by { |s| [SEV[s["severity"]] || 0, s["first_seen"]] }
      inc["severity"] = top["severity"]
      inc["peak_severity"] = [inc["peak_severity"], top["severity"]].compact.max_by { |s| SEV[s] || 0 }
      inc["title"] = basis.size > 1 ? "#{top['title']} ほか#{basis.size - 1}件" : top["title"]
      inc["updated_at"] = now.iso8601
    end

    def trim
      return if @incidents.size <= @keep

      closed = @incidents.values.reject { |i| i["status"] == "open" }.sort_by { |i| i["opened_at"] }
      closed.first(@incidents.size - @keep).each { |i| @incidents.delete(i["id"]) }
    end

    def deep(obj) = JSON.parse(JSON.generate(obj))

    def load
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path)).to_h { |i| [i["id"], i] }
    rescue JSON::ParserError
      {}
    end

    def save
      data = @mutex.synchronize { JSON.generate(@incidents.values) }
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, data)
      File.rename(tmp, @path)
    end
  end
end
