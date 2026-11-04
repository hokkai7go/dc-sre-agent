require "json"
require "securerandom"

module SreAgent
  # ツールを使いながら調査を進める汎用エージェント。
  # 統括エージェントもサブエージェントも同じクラスで、渡すプロンプトとツールだけが違う。
  class Agent
    Tool = Struct.new(:name, :description, :input_schema, :handler, :terminal, keyword_init: true) do
      def to_api = { name: name, description: description, input_schema: input_schema }
    end

    Result = Struct.new(:run_id, :text, :final_payload, :turns, :error, keyword_init: true)

    MAX_TOOL_RESULT_CHARS = 12_000
    TOOL_TIMEOUT = 600

    attr_reader :name, :label

    def initialize(name:, label:, model:, system:, tools:, client:, bus:, max_turns: 8, max_tokens: 4096)
      @name = name
      @label = label
      @model = model
      @system = system
      @tools = tools.to_h { |t| [t.name, t] }
      @client = client
      @bus = bus
      @max_turns = max_turns
      @max_tokens = max_tokens
    end

    def run(task, parent_run: nil, context: {})
      run_id = SecureRandom.hex(4)
      emit("agent.start", run_id, parent_run: parent_run, task: task, model: @model, **context)
      messages = [{ role: "user", content: task }]
      final_payload = nil
      texts = []

      @max_turns.times do |turn|
        res = @client.messages(model: @model, system: @system, messages: messages,
                               tools: @tools.values.map(&:to_api), max_tokens: @max_tokens)
        content = res["content"] || []
        messages << { role: "assistant", content: content }

        content.each do |block|
          next unless block["type"] == "text" && !block["text"].to_s.strip.empty?

          texts << block["text"]
          emit("agent.text", run_id, text: block["text"])
        end

        uses = content.select { |b| b["type"] == "tool_use" }
        if uses.empty?
          return finish(run_id, texts.last.to_s, final_payload, turn + 1)
        end

        results = run_tools(uses, run_id)
        terminal = uses.find { |u| @tools[u["name"]]&.terminal }
        if terminal
          final_payload = terminal["input"]
          return finish(run_id, texts.last.to_s, final_payload, turn + 1)
        end
        messages << { role: "user", content: results }
      end

      msg = "ターン上限(#{@max_turns})に達したため調査を打ち切りました"
      emit("agent.error", run_id, error: msg)
      Result.new(run_id: run_id, text: texts.last.to_s, final_payload: final_payload, turns: @max_turns, error: msg)
    rescue StandardError => e
      emit("agent.error", run_id, error: "#{e.class}: #{e.message}")
      Result.new(run_id: run_id, text: texts&.last.to_s, final_payload: nil, turns: 0, error: e.message)
    end

    private

    def finish(run_id, text, payload, turns)
      emit("agent.done", run_id, text: text, payload: payload, turns: turns)
      Result.new(run_id: run_id, text: text, final_payload: payload, turns: turns)
    end

    # 同じターンで複数のツールが呼ばれたら並列に実行する。
    # 統括エージェントが3つのサブエージェントへ同時に依頼したときに効く。
    def run_tools(uses, run_id)
      threads = uses.map do |use|
        [use, Thread.new do
          tool = @tools[use["name"]]
          emit("agent.tool_call", run_id, tool: use["name"], input: use["input"], tool_use_id: use["id"])
          started = Time.now
          out, is_error =
            if tool.nil?
              ["未知のツールです: #{use['name']}", true]
            elsif tool.terminal
              ["受け付けました", false]
            else
              begin
                v = tool.handler.call(use["input"] || {}, run_id)
                [v.is_a?(String) ? v : JSON.pretty_generate(v), false]
              rescue StandardError => e
                ["ツール実行エラー: #{e.class}: #{e.message}", true]
              end
            end
          out = truncate(out)
          emit("agent.tool_result", run_id, tool: use["name"], tool_use_id: use["id"], error: is_error,
                                            elapsed_ms: ((Time.now - started) * 1000).round,
                                            preview: out[0, 600])
          { type: "tool_result", tool_use_id: use["id"], content: out, is_error: is_error }
        end]
      end
      threads.map do |use, t|
        next t.value if t.join(TOOL_TIMEOUT)

        t.kill
        { type: "tool_result", tool_use_id: use["id"], content: "タイムアウトしました", is_error: true }
      end
    end

    def truncate(s)
      return s if s.size <= MAX_TOOL_RESULT_CHARS

      "#{s[0, MAX_TOOL_RESULT_CHARS]}\n…(#{s.size - MAX_TOOL_RESULT_CHARS}文字省略。条件を絞って再取得してください)"
    end

    def emit(type, run_id, **data)
      @bus.emit(type, agent: @name, agent_label: @label, run_id: run_id, **data)
    end
  end
end
