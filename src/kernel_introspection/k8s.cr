require "kernel_introspection"

module KernelIntrospection
  module K8s
    module Node
      def self.pids(node)
        Log.info { "pids" }
        ls_proc = ClusterTools.exec_by_node("ls /proc/", node)
        Log.info { "pids ls_proc: #{ls_proc}" }
        parsed_ls = KernelIntrospection.parse_ls(ls_proc[:output])
        pids = KernelIntrospection.pids_from_ls_proc(parsed_ls)
        Log.info { "pids pids: #{pids}" }
        pids
      end

      def self.all_statuses_by_pids(pids : Array(String), node) : Array(String)
        Log.info { "all_statuses_by_pids" }
        proc_statuses = pids.map do |pid|
          Log.info { "all_statuses_by_pids pid: #{pid}" }
          proc_status = ClusterTools.exec_by_node("cat /proc/#{pid}/status", node)
          proc_status[:output]
        end

        Log.debug { "proc process_statuses_by_node: #{proc_statuses}" }
        proc_statuses
      end

      def self.status_by_pid(pid, node)
        Log.info { "status_by_pid" }
        status = ClusterTools.exec_by_node("cat /proc/#{pid}/status", node)
        Log.info { "status_by_pid status: #{status}" }
        status[:output]
      end

      def self.cmdline_by_pid(pid : String, node) 
        Log.info { "cmdline_by_pid" }
        cmdline = ClusterTools.exec_by_node("cat /proc/#{pid}/cmdline", node)
        Log.info { "cmdline_by_node cmdline: #{cmdline}" }
        cmdline 
      end

      def self.verify_single_proc_tree(original_parent_pid, name, proctree : Array(Hash(String, String)))
        Log.info { "verify_single_proc_tree pid, name: #{original_parent_pid}, #{name}" }
        verified = true 
        proctree.map do | pt |
          current_pid = "#{pt["Pid"]}".strip
          ppid = "#{pt["PPid"]}".strip
          status_name = "#{pt["Name"]}".strip

          if current_pid == original_parent_pid && ppid != "" && 
            status_name != name
            # todo exclude tini, init, dumbinit?, from violations
            Log.info { "top level parent (i.e. superviser -- first parent with different name): #{status_name}" }
            verified = false

          elsif current_pid == original_parent_pid && ppid != "" && 
            status_name == name

            verified = verify_single_proc_tree(ppid, name, proctree)
          end
        end
        Log.info { "verified?: #{verified}" }
        verified
      end

      def self.proctree_by_pid(potential_parent_pid : String, node : JSON::Any, proc_statuses : (Array(String) | Nil)  = nil) : Array(Hash(String, String)) # array of status hashes
        Log.info { "proctree_by_node potential_parent_pid: #{potential_parent_pid}" }
        proctree = [] of Hash(String, String)
        potential_parent_status : Hash(String, String) | Nil = nil
        unless proc_statuses
          pids = pids(node) 
          Log.info { "proctree_by_pid pids: #{pids}" }
          proc_statuses = all_statuses_by_pids(pids, node)
        end
        Log.debug { "proctree_by_pid proc_statuses: #{proc_statuses}" }
        proc_statuses.each do |proc_status|
          parsed_status = KernelIntrospection.parse_status(proc_status)
          Log.debug { "proctree_by_pid parsed_status: #{parsed_status}" }
          if parsed_status
            ppid = parsed_status["PPid"].strip 
            current_pid = parsed_status["Pid"].strip
            Log.info { "potential_parent_pid, ppid, current_pid #{potential_parent_pid}, #{ppid}, #{current_pid}" }
            # save potential parent pid
            if current_pid == potential_parent_pid
              Log.info { "current_pid == potential_parent_pid" }
              cmdline = cmdline_by_pid(current_pid, node)[:output]
              Log.info { "cmdline: #{cmdline}" }
              potential_parent_status = parsed_status.merge({"cmdline" => cmdline}) 
              proctree << potential_parent_status 
            # Add descendeds of the parent pid
            elsif ppid == potential_parent_pid && ppid != current_pid
              Log.info { "ppid == potential_parent_pid" }
              Log.info { "proctree_by_pid ppid == pid && ppid != current_pid: pid, ppid,
                       current_pid #{potential_parent_pid}, #{ppid}, #{current_pid}" }
              cmdline = cmdline_by_pid(current_pid, node)[:output]
              Log.info { " the matched descendent is cmdline: #{cmdline}" }
              proctree = proctree + proctree_by_pid(current_pid, node, proc_statuses)
            end
          end
        end
        Log.info { "proctree_by_node final proctree: #{proctree}" }
        proctree.each{|x| Log.info { "Process name: #{x["Name"]}, pid: #{x["Pid"]}, ppid: #{x["PPid"]}" } }
        proctree
      end
    end

    def self.proc(pod_name, container_name, namespace : String | Nil = nil)
      Log.info { "proc namespace: #{namespace}" }
      # todo if container_name nil, dont use container (assume one container)
      resp = KubectlClient.exec("-ti #{pod_name} --container #{container_name} -- ls /proc/", namespace: namespace)
      KernelIntrospection.parse_proc(resp[:output].to_s)
    end

    def self.cmdline(pod_name, container_name, pid, namespace : String | Nil = nil)
      Log.info { "cmdline namespace: #{namespace}" }
      # todo if container_name nil, dont use container (assume one container)
      resp = KubectlClient.exec("-ti #{pod_name} --container #{container_name} -- cat /proc/#{pid}/cmdline", namespace: namespace)
      resp[:output].to_s.strip
    end

    def self.status(pod_name, container_name, pid, namespace : String | Nil = nil)
      # todo if container_name nil, dont use container (assume one container)
      Log.info { "status namespace: #{namespace}" }
      resp = KubectlClient.exec("-ti #{pod_name} --container #{container_name} -- cat /proc/#{pid}/status", namespace: namespace)
      KernelIntrospection.parse_status(resp[:output].to_s)
    end

    def self.status_by_proc(pod_name, container_name, namespace : String | Nil = nil)
      Log.info { "status_by_proc namespace: #{namespace}" }
      proc(pod_name, container_name, namespace).map { |pid|
        stat_cmdline = status(pod_name, container_name, pid, namespace)
        stat_cmdline.merge({"cmdline" => cmdline(pod_name, container_name, pid, namespace)}) if stat_cmdline
      }.compact
    end


    alias MatchingProcessInfo = NamedTuple(
      node: JSON::Any,
      pod: JSON::Any,
      container_status: JSON::Any, 
      status: String,
      pid: String,
      cmdline: String
    )

    # #todo overload with regex
    def self.find_first_process(process_name) : (MatchingProcessInfo | Nil)
      Log.info { "find_first_process" }
      ret = nil
      nodes = KubectlClient::Get.schedulable_nodes_list
      nodes.map do |node|
        pods = KubectlClient::Get.pods_by_nodes([node])
        pods.map do |pod|
          status = pod["status"]
          if status["containerStatuses"]?
              container_statuses = status["containerStatuses"].as_a
            Log.debug { "container_statuses: #{container_statuses}" }
            container_statuses.map do |container_status|
              ready = container_status.dig("ready").as_bool
              next unless ready
              container_id = container_status.dig("containerID").as_s
              pid = ClusterTools.node_pid_by_container_id(container_id, node)
              # there are some nodes that wont have a proc with this pid in it
              # e.g. a stand alone pod gets installed on only one node
              process = ClusterTools.exec_by_node("cat /proc/#{pid}/cmdline", node)
              Log.info {"cat /proc/#{pid}/cmdline process: #{process[:output]}" }
              status = ClusterTools.exec_by_node("cat /proc/#{pid}/status", node)
              Log.info {"status: #{status}" }
              if process[:output] =~ /#{process_name}/
                ret = {node: node, pod: pod, container_status: container_status, status: status[:output], pid: pid.to_s, cmdline: process[:output]}
                Log.info { "status found: #{ret}" }
                break 
              end
            end
          end
          break if ret
        end
        break if ret
      end
      ret
    end

    def self.find_matching_processes(process_name) : Array(MatchingProcessInfo)
      Log.info { "find_matching_processes" }
      results = [] of MatchingProcessInfo
      nodes = KubectlClient::Get.schedulable_nodes_list
      nodes.map do |node|
        pods = KubectlClient::Get.pods_by_nodes([node])
        pods.map do |pod|
          status = pod["status"]
          if status["containerStatuses"]?
            container_statuses = status["containerStatuses"].as_a
            Log.debug { "container_statuses: #{container_statuses}" }
            container_statuses.map do |container_status|
              ready = container_status.dig("ready").as_bool
              next unless ready
              container_id = container_status.dig("containerID").as_s
              pid = ClusterTools.node_pid_by_container_id(container_id, node)
              # there are some nodes that wont have a proc with this pid in it
              # e.g. a stand alone pod gets installed on only one node
              process = ClusterTools.exec_by_node("cat /proc/#{pid}/cmdline", node)
              Log.info {"cat /proc/#{pid}/cmdline process: #{process[:output]}" }
              status = ClusterTools.exec_by_node("cat /proc/#{pid}/status", node)
              Log.info {"status: #{status}" }
              if process[:output] =~ /#{process_name}/
                result = {node: node, pod: pod, container_status: container_status, status: status[:output], pid: pid.to_s, cmdline: process[:output]}
                results.push(result)
                Log.for("find_matching_processes").info { "status found: #{result}" }
                # break 
              end
            end
          end
        end
      end
      results
    end

  end
end
