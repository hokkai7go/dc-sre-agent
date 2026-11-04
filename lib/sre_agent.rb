require "json"
require "time"

require_relative "sre_agent/config"
require_relative "sre_agent/event_bus"
require_relative "sre_agent/claude_client"
require_relative "sre_agent/agent"
require_relative "sre_agent/sources/http_get"
require_relative "sre_agent/sources/victoria_metrics"
require_relative "sre_agent/sources/victoria_logs"
require_relative "sre_agent/sources/proxmox"
require_relative "sre_agent/agents/tool_helpers"
require_relative "sre_agent/agents/network_agent"
require_relative "sre_agent/agents/proxmox_agent"
require_relative "sre_agent/agents/log_agent"
require_relative "sre_agent/agents/orchestrator"
require_relative "sre_agent/checks"
require_relative "sre_agent/incident_store"
require_relative "sre_agent/watcher"
require_relative "sre_agent/web_server"

module SreAgent
  # 部品を組み立てて起動する。
  def self.boot(config_path)
    config = Config.load(config_path)
    bus = EventBus.new

    src = config.dig(:sources, default: {})
    vm = Sources::VictoriaMetrics.new(url: src.dig("victoria_metrics", "url"))
    vl = Sources::VictoriaLogs.new(url: src.dig("victoria_logs", "url"))
    pc = src["proxmox"] || {}
    pve = Sources::Proxmox.new(url: pc["url"], token_id: pc["token_id"], token_secret: pc["token_secret"],
                               verify_tls: pc.fetch("verify_tls", true), ca_file: pc["ca_file"])

    checks = {
      network: Checks::Network.new(config: config, vm: vm),
      proxmox: Checks::Proxmox.new(config: config, pve: pve),
      logs: Checks::Logs.new(config: config, vl: vl)
    }
    store = IncidentStore.new(dir: config.data_dir,
                              group_window_minutes: config.dig(:watch, :group_window_minutes, default: 3),
                              resolve_after_cycles: config.dig(:watch, :resolve_after_cycles, default: 2))

    api_key = config.dig(:claude, :api_key).to_s
    client = nil
    orchestrator = nil
    watcher = nil
    if api_key.empty?
      warn "[sre-agent] ANTHROPIC_API_KEY が未設定です。監視とダッシュボードのみで起動します(調査は無効)"
    else
      client = ClaudeClient.new(api_key: api_key, base_url: config.dig(:claude, :base_url, default: "https://api.anthropic.com"))
      subagents = {
        "network" => Agents::NetworkAgent.build(config: config, vm: vm, vl: vl, client: client, bus: bus),
        "proxmox" => Agents::ProxmoxAgent.build(config: config, pve: pve, vl: vl, client: client, bus: bus),
        "logs" => Agents::LogAgent.build(config: config, vl: vl, client: client, bus: bus)
      }
      orchestrator = Agents::Orchestrator.new(config: config, subagents: subagents, client: client, bus: bus,
                                              snapshot_provider: -> { watcher.snapshot })
    end

    watcher = Watcher.new(config: config, checks: checks, store: store, bus: bus, orchestrator: orchestrator)
    web = WebServer.new(host: config.dig(:listen, :host, default: "0.0.0.0"), port: config.dig(:listen, :port, default: 8080).to_i,
                        bus: bus, store: store, watcher: watcher, client: client, config: config,
                        public_dir: File.expand_path("../public", __dir__))
    web.start
    watcher.start
    warn "[sre-agent] #{config.site} ダッシュボード: http://#{config.dig(:listen, :host, default: '0.0.0.0')}:#{config.dig(:listen, :port, default: 8080)}/"
    { config: config, bus: bus, store: store, watcher: watcher, web: web }
  end
end
