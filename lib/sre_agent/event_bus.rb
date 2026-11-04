require "json"
require "time"

module SreAgent
  # ダッシュボードへ流すイベントの中継所。
  # 直近のイベントをリングバッファに持ち、SSEで再接続したブラウザにも続きを渡せるようにする。
  class EventBus
    Event = Struct.new(:id, :ts, :type, :data, keyword_init: true) do
      def to_h = { id: id, ts: ts, type: type, data: data }
    end

    def initialize(capacity: 1000)
      @capacity = capacity
      @buffer = []
      @subscribers = {}
      @seq = 0
      @mutex = Mutex.new
    end

    def emit(type, **data)
      event = nil
      subs = nil
      @mutex.synchronize do
        @seq += 1
        event = Event.new(id: @seq, ts: Time.now.utc.iso8601(3), type: type, data: data)
        @buffer << event
        @buffer.shift while @buffer.size > @capacity
        subs = @subscribers.values
      end
      subs.each { |q| q << event if q.size < 5000 }
      event
    end

    # 新しい購読を作る。after_id 以降のバッファ済みイベントを先に渡す。
    def subscribe(after_id: nil, replay: 200)
      q = Queue.new
      token = Object.new
      @mutex.synchronize do
        backlog = after_id ? @buffer.select { |e| e.id > after_id } : @buffer.last(replay)
        backlog.each { |e| q << e }
        @subscribers[token] = q
      end
      [token, q]
    end

    def unsubscribe(token)
      @mutex.synchronize { @subscribers.delete(token) }
    end

    def last_id = @mutex.synchronize { @seq }

    def recent(n = 200, types: nil)
      @mutex.synchronize do
        list = types ? @buffer.select { |e| types.include?(e.type) } : @buffer
        list.last(n)
      end
    end
  end
end
