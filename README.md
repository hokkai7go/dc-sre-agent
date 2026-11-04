# DC監視エージェント

大阪DCのネットワーク機器・Proxmox・syslogを見張り、異常を見つけたら Claude のエージェントが原因を調べて報告する仕組みです。調べている様子と結果はダッシュボードでリアルタイムに見られます。

Ruby 3.3 の標準ライブラリだけで書いてあり、gem のインストールは要りません。

## 仕組み

監視は二段構えになっています。

一段目は LLM を使わない定期チェックです。60秒ごとに VictoriaMetrics・VictoriaLogs・Proxmox API を読み、しきい値で判定して「シグナル」を出します。機器への疎通断、SNMP取得失敗、リンクのフラップ、インターフェースのエラー増加や帯域逼迫、Proxmoxノードの停止やCPU・メモリ・ストレージの逼迫、重要VMの停止、バックアップなどのタスク失敗、ホストごとのエラーログ急増、セキュリティ上気になるログパターンの急増を拾います。平常時はここだけが動くので、Claude API の費用はかかりません。

二段目がエージェントです。シグナルがインシデントになると、統括エージェントが起動します。統括エージェント自身は監視データを直接読めず、ネットワーク担当・Proxmox担当・ログ担当の3つのサブエージェントへ依頼して事実を集めます。依頼は同じターンにまとめて出せるようにしてあり、そのとき3担当は並列に動きます。担当どうしの結果をつき合わせたうえで、統括エージェントが「確認した事実」「推定原因」「影響」「次にやること」を決まった形式で報告します。

```
              ┌──────────── 定期チェック(LLMなし・60秒ごと) ────────────┐
              │  VictoriaMetrics   VictoriaLogs   Proxmox API          │
              └──────────────┬─────────────────────────────────────────┘
                             │ シグナル → インシデント化(同時刻のものは1件にまとめる)
                             ▼
                    統括エージェント(Opus)
               ┌─────────────┼──────────────┐   並列に依頼
               ▼             ▼              ▼
        ネットワーク担当   Proxmox担当       ログ担当      (Sonnet)
        SNMP/ICMP/機器ログ ノード/VM/タスク  syslog横断検索
                             │
                             ▼
                報告 → ダッシュボード(SSEでリアルタイム表示)
```

ダッシュボードからは統括エージェントに直接質問することもできます。「昨夜からpve02のメモリが増えている理由は？」のように聞くと、同じ流れで担当へ依頼して答えます。

## 読み取り専用であることの担保

エージェントには監視対象を変更する手段を一切渡していません。HTTPクライアントは GET しか出せない作りにしてあり、Proxmox には PVEAuditor ロールだけを付けたトークンで接続します。プロンプトでも読み取り専用であることを明示し、推奨アクションは人が実行する手順として書かせています。

## 費用の抑え方

調査が走るのは、新しいインシデントができたとき、既存インシデントに新しいシグナルが加わったとき、手動で再調査や質問をしたときだけです。同じインシデントの再調査は15分空けます(ただし重大度が上がったときは待たずに調べ直します)。自動調査は1日30件までにしてあり、超えた分はダッシュボードに「上限に達した」と出して調査しません。担当への依頼は1回の調査で6回まで、ツール結果は12,000字で切り詰めます。system プロンプトとツール定義にはプロンプトキャッシュを指定しています。

これらはすべて `config.yml` の `claude:` で変えられます。

## セットアップ

### 1. Proxmox に読み取り専用トークンを作る

```sh
pveum user add sre-agent@pve --comment "SRE監視エージェント(読み取り専用)"
pveum user token add sre-agent@pve dashboard --privsep 1
pveum acl modify / --tokens 'sre-agent@pve!dashboard' --roles PVEAuditor
```

2行目で表示されるシークレットは一度しか出ないので控えておきます。Proxmox の証明書が自己署名なら、ノードの `/etc/pve/pve-root-ca.pem` をコピーして `config.yml` の `ca_file` に指定します。

### 2. SNMP と ICMP のメトリクスを VictoriaMetrics に入れる

`deploy/scrape.example.yml` を既存の scrape 設定に足し、`snmp-exporter` と `blackbox-exporter` を立てます(`deploy/docker-compose.yml` に入れてあります)。RTX1300 側では SNMPv2c の読み取りコミュニティを設定しておきます。

syslog はすでに VictoriaLogs に入っている前提です。Proxmox ノードの syslog も同じ基盤に送っておくと、Proxmox担当がノードのOSログまで読めるようになります。

### 3. 設定して起動する

```sh
cd /opt/sre-agent/deploy
cp ../config/config.example.yml config.yml   # 機器・しきい値を編集
cp .env.example .env                          # APIキーとトークンを記入
sudo -u isinfra docker compose up -d --build
```

`docker-compose.yml` のネットワーク名(`logstack` / `proxy`)は既存の compose に合わせて変えてください。`pve-root-ca.pem` を使わない場合はその volume 行を消します(存在しないファイルをマウントするとディレクトリが作られて起動に失敗します)。

Traefik 経由で `sre.intra.i-style.jp` に出す labels を入れてあります。質問機能は API 費用が発生するので、OAuth の forward-auth を用意したら `middlewares` の行を有効にしてください。それまではVPN内からしか届かないことを前提にしています。

`ANTHROPIC_API_KEY` を空にして起動すると、エージェントなしの監視とダッシュボードだけで動きます。しきい値の調整を先に済ませたいときに使えます。

Docker を使わずに動かす場合は Ruby 3.3 があれば足ります。

```sh
ruby bin/sre-agent config/config.yml
```

## 調整のしどころ

最初の数日は誤検知が出るはずです。とくに `watch.logs.security_patterns` の文言は RTX のファームウェアで変わるので、実際の syslog を見て合わせてください。`error_threshold` もホストの平常時のエラー件数を見てから決めるのがよいです。

担当エージェントの調べ方は `lib/sre_agent/agents/*_agent.rb` の system プロンプトに書いてあります。「この機器はまずここを見る」といった現場の勘所はここに足していくと効きます。担当を増やしたいとき(たとえば UPS や NAS)は、同じ形でエージェントを1つ作り、`orchestrator.rb` の `tools` に `ask_xxx_agent` を1行足すだけです。

## 動作確認

実機がなくても、モックで一通りの流れを確かめられます。

```sh
ruby test/mock_backends.rb 9900 &
ruby bin/sre-agent test/config.mock.yml &
ruby -rtime test/run_e2e.rb       # 平常 → 障害 → 自動調査 → 報告 → 復旧 → 質問 を確認
```

ブラウザで http://127.0.0.1:8088/ を開くと画面を見られます。

## ファイル構成

```
bin/sre-agent                 起動スクリプト
lib/sre_agent/agent.rb        ツールを使う汎用エージェント(並列ツール実行つき)
lib/sre_agent/agents/         統括エージェントと3つの担当エージェント
lib/sre_agent/checks.rb       LLMを使わない定期チェック
lib/sre_agent/incident_store.rb  シグナルのインシデント化、復旧判定、調査結果の保存
lib/sre_agent/watcher.rb      チェックの定期実行と調査キュー
lib/sre_agent/sources/        VictoriaMetrics / VictoriaLogs / Proxmox の読み取りクライアント
lib/sre_agent/web_server.rb   ダッシュボードとAPI、SSE
public/                       ダッシュボードの画面
deploy/                       Dockerfile以外のデプロイ資材
test/                         モックと通しテスト
```
