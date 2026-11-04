"use strict";
// ダッシュボード。最初に /api/state で全体を取り、以後は /events(SSE) の差分で更新する。

const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const SEV = { info: 0, warning: 1, critical: 2 };
const SEV_JA = { info: "情報", warning: "注意", critical: "重大" };

const st = { site: "", grafana: null, snapshot: null, incidents: new Map(), runs: new Map(), lastId: 0, agent: null };

function hms(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleTimeString("ja-JP", { hour12: false, timeZone: "Asia/Tokyo" });
}
function mdhm(iso) {
  if (!iso) return "";
  return new Date(iso).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Tokyo" });
}
function pct(v) { return v == null ? "—" : `${(v * 100).toFixed(1)}%`; }
function levelOf(v, warn, crit) { return v == null ? "" : v >= crit ? "critical" : v >= warn ? "warning" : ""; }

// ---------- 監視の状態 ----------
function renderSnapshot() {
  const s = st.snapshot;
  if (!s || !s.at) return;
  $("#last-check").textContent = `${hms(s.at)}(${s.took_ms}ms)`;
  if (s.agent) st.agent = s.agent;
  renderBudget();

  const sigs = s.signals || [];
  const bySrc = (src) => sigs.filter((x) => x.source === src);
  const worst = (list) => list.reduce((m, x) => Math.max(m, SEV[x.severity] ?? 0), -1);

  // ヘッダーの一文
  const crit = sigs.filter((x) => x.severity === "critical").length;
  const warn = sigs.filter((x) => x.severity === "warning").length;
  const v = $("#verdict");
  if (!crit && !warn) { v.textContent = "異常は検知していません"; v.dataset.level = "ok"; }
  else {
    v.textContent = [crit && `重大 ${crit}件`, warn && `注意 ${warn}件`].filter(Boolean).join("、") + "を検知しています";
    v.dataset.level = crit ? "critical" : "warning";
  }
  document.title = crit || warn ? `(${crit + warn}) ${st.site} 監視` : `${st.site} 監視`;

  const net = s.network || {}, pve = s.proxmox || {}, logs = s.logs || {};
  const devs = net.devices || [];
  const down = devs.filter((d) => d.ping === false).length;
  setSys("network", bySrc("network"), net.error ? "データ取得不可" : down ? `${down}台に疎通なし` : "正常",
    `${devs.length}台を監視 ・ 応答最大 ${Math.max(0, ...devs.map((d) => d.rtt_ms || 0)).toFixed(1)}ms`);
  const nodes = pve.nodes || [];
  setSys("proxmox", bySrc("proxmox"), pve.error ? "データ取得不可" : `${nodes.filter((n) => n.status === "online").length}/${nodes.length}ノード稼働`,
    pve.guests ? `ゲスト ${pve.guests.running}/${pve.guests.total} 起動中・失敗タスク ${pve.failed_tasks}件` : "");
  const errs = (logs.hosts || []).reduce((a, h) => a + h.errors, 0);
  setSys("logs", bySrc("logs"), logs.error ? "データ取得不可" : `直近${logs.window_minutes ?? "-"}分のエラー ${errs}件`,
    `${(logs.hosts || []).length}ホストから受信`);

  // 機器表
  $("#devices").innerHTML = devs.length ? devs.map((d) => {
    const cls = d.ping === false ? "critical" : d.ping ? "ok" : "";
    return `<tr><td>${esc(d.name)}<small>${esc(d.role || d.instance)}</small></td>
      <td><span class="dot ${cls}"></span>${d.ping === false ? "なし" : d.ping ? "あり" : "不明"}</td>
      <td class="num">${d.rtt_ms != null ? d.rtt_ms.toFixed(1) + "ms" : "—"}</td>
      <td>${d.snmp == null ? "—" : d.snmp ? "取得中" : '<span style="color:var(--warn)">失敗</span>'}</td></tr>`;
  }).join("") : `<tr><td colspan="4" class="muted">${esc(net.error || "監視対象がありません。config.yml の devices を確認してください")}</td></tr>`;

  // Proxmox
  $("#guests").textContent = pve.guests ? `ゲスト ${pve.guests.running}/${pve.guests.total} 起動中` : "";
  $("#nodes").innerHTML = nodes.length ? nodes.map((n) => {
    if (n.status !== "online") return `<div class="bar bar-off"><span class="bar-name">${esc(n.node)}</span><span>オフライン</span><span></span></div>`;
    return `<div class="bar" title="上: CPU ${pct(n.cpu)} / 下: メモリ ${pct(n.mem)}">
      <span class="bar-name">${esc(n.node)}</span>
      <span class="bar-track double"><span><span class="bar-fill ${levelOf(n.cpu, .8, .9)}" style="width:${(n.cpu || 0) * 100}%;display:block"></span></span>
      <span><span class="bar-fill ${levelOf(n.mem, .8, .9)}" style="width:${(n.mem || 0) * 100}%;display:block"></span></span></span>
      <span class="bar-val">${pct(n.cpu)}<br>${pct(n.mem)}</span></div>`;
  }).join("") : `<p class="muted">${esc(pve.error || "ノード情報がありません")}</p>`;
  $("#storages").innerHTML = (pve.storages || []).map((x) =>
    `<div class="bar"><span class="bar-name" title="${esc(x.node)}">${esc(x.storage)}${x.shared ? "" : `<span class="muted"> ${esc(x.node)}</span>`}</span>
     <span class="bar-track"><span class="bar-fill ${levelOf(x.used, .85, .95)}" style="width:${x.used * 100}%;display:block"></span></span>
     <span class="bar-val">${pct(x.used)}</span></div>`).join("");

  // ログ
  $("#log-window").textContent = logs.window_minutes ? `直近${logs.window_minutes}分` : "";
  $("#log-hosts").innerHTML = (logs.hosts || []).slice(0, 15).map((h) =>
    `<tr><td>${esc(h.host)}</td><td class="num">${h.total.toLocaleString()}</td>
     <td class="num" ${h.errors ? 'style="color:var(--warn)"' : ""}>${h.errors.toLocaleString()}</td></tr>`).join("")
    || `<tr><td colspan="3" class="muted">${esc(logs.error || "受信なし")}</td></tr>`;
  $("#security").innerHTML = (logs.security || []).map((x) =>
    `<li class="${x.hits ? "hit" : ""}"><span>${esc(x.name)}</span><span>${x.hits}件</span></li>`).join("");
  $("#recent-errors").innerHTML = (logs.recent_errors || []).map((l) =>
    `<li><span class="lh">${hms(l.time)} ${esc(l.host)} ${esc(l.app || "")}</span> ${esc(l.msg)}</li>`).join("")
    || '<li class="lh">直近1時間のエラーログはありません</li>';
}

function setSys(key, sigs, state, detail) {
  const el = document.querySelector(`.sys[data-sys="${key}"]`);
  const w = sigs.reduce((m, x) => Math.max(m, SEV[x.severity] ?? 0), -1);
  el.dataset.level = w >= 2 ? "critical" : w === 1 ? "warning" : "ok";
  el.querySelector(".sys-state").textContent = state;
  el.querySelector(".sys-detail").textContent = detail;
}

function renderBudget() {
  const a = st.agent;
  if (!a) return;
  $("#agent-budget").textContent = a.llm_enabled ? `${a.investigations_today} / ${a.daily_limit}件` : "無効(APIキー未設定)";
  $("#ask-q").disabled = !a.llm_enabled;
  $("#ask button").disabled = !a.llm_enabled;
}

// ---------- インシデント ----------
function incStatus(inc) {
  const inv = (inc.investigations || []).at(-1);
  if (inv && inv.status === "running") return ["investigating", "調査中"];
  if (inc.status === "resolved") return ["", "復旧"];
  if (inc.kind === "inquiry") return ["", inc.status === "answered" ? "回答済み" : "受付"];
  if (inc.acknowledged_at) return ["", "確認済み"];
  return ["", inv ? "報告あり" : "未調査"];
}

function renderIncidents() {
  const showClosed = $("#show-closed").checked;
  const list = [...st.incidents.values()]
    .filter((i) => showClosed || (i.status === "open" || (i.kind === "inquiry" && Date.now() - new Date(i.opened_at) < 3600e3)))
    .sort((a, b) => (b.status === "open") - (a.status === "open") || (SEV[b.severity] - SEV[a.severity]) || b.opened_at.localeCompare(a.opened_at))
    .slice(0, 30);
  $("#incidents").innerHTML = list.length ? list.map(incHtml).join("") : '<li class="empty">対応中のインシデントはありません</li>';
}

function incHtml(inc) {
  const [cls, label] = incStatus(inc);
  const inv = (inc.investigations || []).filter((x) => x.report).at(-1);
  const r = inv?.report;
  const sigs = Object.values(inc.signals || {});
  const runningInv = (inc.investigations || []).at(-1)?.status === "running";
  return `<li class="inc" data-sev="${esc(r?.severity || inc.severity)}" data-status="${esc(inc.status)}">
    <div class="inc-head">
      <div><div class="inc-title">${esc(r?.title || inc.title)}</div>
        <div class="inc-sub">${esc(inc.id)} ・ ${mdhm(inc.opened_at)} 検知${inc.resolved_at ? ` ・ ${mdhm(inc.resolved_at)} 復旧` : ""}</div></div>
      <span class="inc-badge ${cls}">${label}</span>
    </div>
    <div class="inc-body">
      ${inc.question ? `<p class="muted" style="margin-bottom:8px">質問: ${esc(inc.question)}</p>` : ""}
      ${sigs.length ? `<ul class="signals">${sigs.map((s) => `<li class="${s.active ? "" : "cleared"}"><span class="dot ${esc(s.severity)}"></span>${esc(s.title)} <span class="muted">${esc(s.detail)}</span></li>`).join("")}</ul>` : ""}
      ${r ? reportHtml(r, inv) : inv?.error ? `<p class="muted">調査に失敗しました: ${esc(inv.error)}</p>` : ""}
      ${inc.kind === "alert" && inc.status === "open" ? `<div class="inc-actions">
        ${st.agent?.llm_enabled ? `<button class="btn primary" data-act="investigate" data-id="${esc(inc.id)}" ${runningInv ? "disabled" : ""}>再調査する</button>` : ""}
        ${inc.acknowledged_at ? "" : `<button class="btn" data-act="ack" data-id="${esc(inc.id)}">確認済みにする</button>`}
      </div>` : ""}
    </div></li>`;
}

function reportHtml(r, inv) {
  const list = (a, tag = "ul") => (a && a.length ? `<${tag}>${a.map((x) => `<li>${esc(x)}</li>`).join("")}</${tag}>` : "");
  return `<div class="report">
    <p>${esc(r.summary)}</p>
    ${r.findings?.length ? `<div><h4>確認した事実</h4>${list(r.findings)}</div>` : ""}
    ${r.probable_cause ? `<div><h4>推定原因</h4><p>${esc(r.probable_cause)}</p></div>` : ""}
    ${r.impact ? `<div><h4>影響</h4><p>${esc(r.impact)}</p></div>` : ""}
    ${r.recommended_actions?.length ? `<div><h4>次にやること</h4>${list(r.recommended_actions, "ol")}</div>` : ""}
    <p class="confidence">確度 ${esc({ low: "低", medium: "中", high: "高" }[r.confidence] || r.confidence || "—")} ・ ${hms(inv.finished_at)} 報告</p>
  </div>`;
}

$("#incidents").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-act]");
  if (!b) return;
  b.disabled = true;
  await post(`/api/incidents/${encodeURIComponent(b.dataset.id)}/${b.dataset.act}`, {});
});
$("#show-closed").addEventListener("change", renderIncidents);

// ---------- エージェントの動き ----------
function onAgentEvent(ev) {
  const d = ev.data;
  let run = st.runs.get(d.run_id);
  if (ev.type === "agent.start") {
    run = { id: d.run_id, agent: d.agent, label: d.agent_label, parent: d.parent_run, task: d.task, ts: ev.ts,
            steps: [], children: [], live: true, incident: d.incident_id, inquiry: d.inquiry };
    st.runs.set(d.run_id, run);
    if (d.parent_run && st.runs.get(d.parent_run)) st.runs.get(d.parent_run).children.push(d.run_id);
    return;
  }
  if (!run) return;
  if (ev.type === "agent.text") run.steps.push({ k: "text", text: d.text });
  if (ev.type === "agent.tool_call") run.steps.push({ k: "tool", id: d.tool_use_id, name: d.tool, input: d.input, pending: true });
  if (ev.type === "agent.tool_result") {
    const s = run.steps.find((x) => x.id === d.tool_use_id);
    if (s) Object.assign(s, { pending: false, err: d.error, preview: d.preview, ms: d.elapsed_ms });
  }
  if (ev.type === "agent.done") { run.live = false; run.done = d; }
  if (ev.type === "agent.error") { run.live = false; run.steps.push({ k: "err", text: d.error }); }
}

const TOOL_JA = {
  ask_network_agent: "ネットワーク担当へ依頼", ask_proxmox_agent: "Proxmox担当へ依頼", ask_logs_agent: "ログ担当へ依頼",
  current_snapshot: "全体状況を確認", submit_report: "報告を提出",
};

function stepsHtml(run, childIds) {
  // 連続した依頼(=同じターンで並列に出した依頼)を、横並びのレーン1段にまとめる
  const children = childIds.map((id) => st.runs.get(id)).filter(Boolean);
  let next = 0;
  return run.steps.map((s, i) => {
    if (s.k === "text") return `<li class="step text">${esc(s.text)}</li>`;
    if (s.k === "err") return `<li class="step err-msg">${esc(s.text)}</li>`;
    if (s.name?.startsWith("ask_")) {
      if (run.steps[i - 1]?.name?.startsWith("ask_")) return "";
      let n = 0;
      while (run.steps[i + n]?.name?.startsWith("ask_")) n++;
      const lanes = children.slice(next, next + n);
      next += n;
      return lanes.length ? `<li class="lanes">${lanes.map(laneHtml).join("")}</li>`
        : `<li class="step tool pending"><span class="tname">${esc(TOOL_JA[s.name])}</span></li>`;
    }
    if (s.name === "submit_report") return `<li class="step tool"><span class="tname">${TOOL_JA[s.name]}</span></li>`;
    const input = s.input && Object.keys(s.input).length ? JSON.stringify(s.input) : "";
    return `<li class="step tool ${s.pending ? "pending" : ""} ${s.err ? "err" : ""}">
      <div style="min-width:0"><span class="tname">${esc(TOOL_JA[s.name] || s.name)}</span>
      ${input ? ` <code>${esc(input.length > 160 ? input.slice(0, 160) + "…" : input)}</code>` : ""}
      ${s.preview ? `<details><summary>結果 ${s.ms != null ? `(${(s.ms / 1000).toFixed(1)}秒)` : ""}</summary><pre>${esc(s.preview)}</pre></details>` : ""}</div></li>`;
  }).join("");
}

function laneHtml(c) {
  return `<div class="lane ${c.live ? "live" : ""}">
    <div class="run-head"><span class="run-who">${esc(c.label)}担当</span><span class="run-time">${c.live ? "調査中" : hms(c.ts)}</span></div>
    <p class="run-task">${esc(c.task)}</p>
    <ul class="steps">${stepsHtml({ ...c, steps: c.steps.filter((s) => !(s.k === "text" && s.text === c.done?.text)) }, c.children)}
      ${c.done?.text ? `<li class="step final">${esc(c.done.text)}</li>` : ""}</ul>
  </div>`;
}

function renderRuns() {
  const tops = [...st.runs.values()].filter((r) => !r.parent).sort((a, b) => b.ts.localeCompare(a.ts)).slice(0, 12);
  $("#runs").innerHTML = tops.length ? tops.map((r) => {
    const title = r.inquiry ? "質問への回答" : r.incident ? `${r.incident} の調査` : "調査";
    return `<section class="run ${r.live ? "live" : ""}">
      <div class="run-head"><span class="run-who">${esc(r.label)}エージェント ・ ${esc(title)}</span><span class="run-time">${hms(r.ts)}${r.live ? " 開始・進行中" : ""}</span></div>
      <ul class="steps">${stepsHtml(r, r.children)}</ul>
    </section>`;
  }).join("") : '<p class="empty">まだ調査は行われていません。異常を検知すると自動で調査が始まります。上の欄から質問もできます。</p>';
}

let runsDirty = false;
function scheduleRuns() {
  if (runsDirty) return;
  runsDirty = true;
  requestAnimationFrame(() => {
    // 開いている結果の折りたたみ状態を保つ
    const open = [...document.querySelectorAll("#runs details[open]")].map((d) => d.closest(".step")?.textContent?.slice(0, 40));
    renderRuns();
    if (open.length) document.querySelectorAll("#runs details").forEach((d) => { if (open.includes(d.closest(".step")?.textContent?.slice(0, 40))) d.open = true; });
    runsDirty = false;
  });
}

// ---------- 質問 ----------
$("#ask").addEventListener("submit", async (e) => {
  e.preventDefault();
  const q = $("#ask-q").value.trim();
  if (!q) return;
  $("#ask-msg").textContent = "統括エージェントに送りました。下に調査の様子が表示されます";
  const res = await post("/api/ask", { question: q });
  if (res.ok) $("#ask-q").value = "";
  else $("#ask-msg").textContent = `送信できませんでした: ${(await res.json()).error}`;
});

function post(url, body) {
  return fetch(url, { method: "POST", headers: { "content-type": "application/json", "x-requested-with": "sre-dashboard" }, body: JSON.stringify(body) });
}

// ---------- 接続 ----------
function handle(ev) {
  if (ev.id) st.lastId = ev.id;
  if (ev.type === "snapshot") { st.snapshot = ev.data.snapshot; renderSnapshot(); return; }
  if (ev.type.startsWith("incident.")) {
    const inc = ev.data.incident;
    if (inc) st.incidents.set(inc.id, inc);
    renderIncidents();
    return;
  }
  if (ev.type.startsWith("agent.")) { onAgentEvent(ev); scheduleRuns(); }
}

async function init() {
  const s = await (await fetch("/api/state")).json();
  st.site = s.site;
  $("#site").textContent = `${s.site} 監視エージェント`;
  if (s.grafana_url) document.querySelectorAll("[data-grafana]").forEach((a) => { a.href = s.grafana_url; a.hidden = false; a.target = "_blank"; a.rel = "noopener"; });
  st.agent = s.agent;
  st.snapshot = s.snapshot;
  s.incidents.forEach((i) => st.incidents.set(i.id, i));
  s.activity.forEach((e) => { if (e.type.startsWith("agent.")) onAgentEvent(e); });
  st.lastId = s.last_event_id;
  renderSnapshot(); renderBudget(); renderIncidents(); renderRuns();
  connect();
}

function connect() {
  const es = new EventSource(`/events?after=${st.lastId}`);
  const conn = $("#conn");
  es.onopen = () => { conn.textContent = "リアルタイム"; conn.dataset.state = "live"; };
  es.onerror = () => { conn.textContent = "再接続中"; conn.dataset.state = "lost"; };
  ["snapshot", "incident.opened", "incident.updated", "incident.resolved", "incident.investigating", "incident.report",
   "agent.start", "agent.text", "agent.tool_call", "agent.tool_result", "agent.done", "agent.error", "agent.skipped", "watcher.error"]
    .forEach((t) => es.addEventListener(t, (m) => handle(JSON.parse(m.data))));
}

init().catch((e) => { $("#verdict").textContent = `ダッシュボードを初期化できません: ${e.message}`; });
