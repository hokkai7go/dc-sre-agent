module SreAgent
  module Sources
    # Proxmox VE API。PVEAuditor ロールを付けたAPIトークンで読む想定。
    class Proxmox
      def initialize(url:, token_id:, token_secret:, verify_tls: true, ca_file: nil)
        @http = HttpGet.new(url, headers: { "Authorization" => "PVEAPIToken=#{token_id}=#{token_secret}" },
                                 verify_tls: verify_tls, ca_file: ca_file)
      end

      def resources(type: nil)
        data("/api2/json/cluster/resources", type ? { type: type } : {})
      end

      def node_status(node)
        data("/api2/json/nodes/#{seg(node)}/status")
      end

      def vm_status(node, vmid, kind: "qemu")
        kind = %w[qemu lxc].include?(kind) ? kind : "qemu"
        data("/api2/json/nodes/#{seg(node)}/#{kind}/#{vmid.to_i}/status/current")
      end

      def tasks(limit: 50, errors: false)
        list = data("/api2/json/cluster/tasks")
        list = list.select { |t| t["status"] && t["status"] != "OK" } if errors
        list.first(limit)
      end

      def storage(node)
        data("/api2/json/nodes/#{seg(node)}/storage")
      end

      def cluster_status
        data("/api2/json/cluster/status")
      end

      # RRD(性能履歴)。timeframe: hour/day/week
      def rrd(node, vmid: nil, kind: "qemu", timeframe: "hour")
        tf = %w[hour day week].include?(timeframe) ? timeframe : "hour"
        path = vmid ? "/api2/json/nodes/#{seg(node)}/#{kind == 'lxc' ? 'lxc' : 'qemu'}/#{vmid.to_i}/rrddata" : "/api2/json/nodes/#{seg(node)}/rrddata"
        data(path, { timeframe: tf, cf: "AVERAGE" })
      end

      private

      def data(path, params = {})
        @http.get_json(path, params)["data"]
      end

      def seg(s) = s.to_s.gsub(/[^\w.-]/, "")
    end
  end
end
