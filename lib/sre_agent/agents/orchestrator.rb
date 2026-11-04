module SreAgent
  module Agents
    # 統括エージェント。自分ではデータを読まず、3つのサブエージェントへ依頼して結果をまとめる。
    class Orchestrator
      include ToolHelpers

      REPORT_SCHEMA = {
        severity: { type: "string", enum: %w[info warning critical], description: "影響度" },
        title: { type: "string", description: "一行の見出し(40字以内)" },
        summary: { type: "string", description: "何が起きていて、いま何をすべきかを3〜5文で" },
        findings: { type: "array", items: { type: "string" }, description: "確認できた事実。機器名・値・時刻を含める" },
        probable_cause: { type: "string", description: "推定原因。確度が低ければそう書く" },
        impact: { type: "string", description: "利用者・サービスへの影響" },
        recommended_actions: { type: "array", items: { type: "string" }, description: "人が行う次の手順。優先度順" },
        confidence: { type: "string", enum: %w[low medium high], description: "結論の確度" }
      }.freeze

      def initialize(config:, subagents:, snapshot_provider:, client:, bus:)
        @config = config
        @subagents = subagents
        @snapshot_provider = snapshot_provider
        @max_delegations = config.dig(:claude, :max_delegations, default: 6)
        @counts = Hash.new(0)
        @counts_mutex = Mutex.new
        @agent = Agent.new(name: "orchestrator", label: "統括", model: config.dig(:claude, :orchestrator_model),
                           system: system_prompt, tools: tools, client: client, bus: bus,
                           max_turns: config.dig(:claude, :orchestrator_max_turns, default: 10))
      end

      def investigate(incident)
        signals = incident["signals"].values.select { |s| s["active"] }.map do |s|
          "- [#{s['severity']}] #{s['title']}: #{s['detail']}(初検知 #{jst(s['first_seen'])})"
        end
        task = <<~TXT
          監視でインシデントを検知しました。原因と影響を調べ、submit_report で報告してください。
          インシデント: #{incident['id']} #{incident['title']}
          検知時刻: #{jst(incident['opened_at'])}
          検知したシグナル:
          #{signals.join("\n")}
        TXT
        run(task, incident_id: incident["id"])
      end

      def ask(question)
        task = <<~TXT
          運用担当者からの質問です。必要なサブエージェントに確認したうえで、submit_report で回答してください。
          異常がなければ severity は info にします。
          質問: #{question}
        TXT
        run(task, inquiry: true)
      end

      private

      def run(task, **context)
        result = @agent.run(task, context: context)
        @counts_mutex.synchronize { @counts.delete(result.run_id) }
        report = result.final_payload
        report ||= {
          "severity" => "warning", "title" => "調査を完了できませんでした",
          "summary" => [result.error, result.text].compact.join("\n").strip, "findings" => [],
          "recommended_actions" => ["ダッシュボードのエージェント活動ログを確認してください"], "confidence" => "low"
        }
        { run_id: result.run_id, report: report, error: result.error }
      end

      def jst(iso)
        Time.parse(iso.to_s).getlocal("+09:00").strftime("%Y-%m-%d %H:%M:%S")
      rescue ArgumentError
        iso.to_s
      end

      def system_prompt
        <<~TXT
          あなたは#{@config.site}の監視を統括するSREエージェントです。
          ネットワーク機器・Proxmoxサーバ・ログの3人の担当サブエージェントを指揮し、状況を判断して人に報告します。
          あなた自身は監視データを直接読めません。必ずサブエージェントへ依頼して事実を集めてください。

          進め方:
          1. まず current_snapshot で全体の状態を確認する。
          2. 関係しそうなサブエージェントへ、同じターンでまとめて並列に依頼する。
             依頼文には対象(機器名、ノード名、VMID)、時間帯、観測された症状を具体的に書く。
             たとえば「rtx1300への疎通が10:02から失敗。直前のsyslogとインターフェース状態を確認して」のように。
          3. 担当どうしの結果をつき合わせる。例: ネットワーク断の時刻とProxmoxノードのログが一致するか。
             矛盾や不足があれば、絞った質問でもう一度依頼する。
          4. submit_report で報告して終える。サブエージェントへの依頼は合計#{@max_delegations}回までです。

          報告の原則:
          - あなたもサブエージェントも読み取り専用です。推奨アクションは人が実行する手順として書く。
          - 事実と推測を分ける。サブエージェントが「取得できなかった」と言った点は、そのまま不明として扱う。
          - 一時的なゆらぎや誤検知と判断したら、そう書いて severity を下げてよい。
          - 日本語で、夜間に起こされた担当者が30秒で状況をつかめる書き方にする。
        TXT
      end

      def tools
        delegate = lambda do |key, desc|
          tool("ask_#{key}_agent", desc,
               { question: str("担当者への具体的な依頼文") }, required: %w[question]) do |i, run_id|
            n = @counts_mutex.synchronize { @counts[run_id] += 1 }
            next "依頼回数の上限(#{@max_delegations}回)に達しました。手元の情報で submit_report してください。" if n > @max_delegations

            res = @subagents.fetch(key).run(i["question"], parent_run: run_id)
            res.error ? "#{res.text}\n(担当エージェントでエラー: #{res.error})" : res.text
          end
        end

        [
          tool("current_snapshot", "定期監視が最後に集めた全体状況(機器の疎通、ノード、ストレージ、ログ件数、発報中のシグナル)を返す") do |_i, _r|
            @snapshot_provider.call
          end,
          delegate.("network", "ネットワーク担当に依頼する。ルータ・スイッチの疎通、インターフェース、帯域、機器ログを調べられる"),
          delegate.("proxmox", "Proxmox担当に依頼する。ノード・VM/CTの状態と性能履歴、ストレージ、タスク失敗、ノードのOSログを調べられる"),
          delegate.("logs", "ログ担当に依頼する。全ホストのsyslogを横断検索し、件数の偏りや増加時刻、セキュリティ上不審な行を調べられる"),
          tool("submit_report", "調査結果を報告して終了する。必ず最後にこれを呼ぶ",
               REPORT_SCHEMA, required: %w[severity title summary findings recommended_actions confidence], terminal: true)
        ]
      end
    end
  end
end
