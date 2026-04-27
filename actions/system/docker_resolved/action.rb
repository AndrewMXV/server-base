Action :docker_resolved, default: true, depends: [:base, :docker] do
  resolved_unit_cmd = "state=$(systemctl show -p LoadState --value systemd-resolved.service 2>/dev/null || true); [ \"$state\" != \"not-found\" ] && echo yes || true"

  check do |_params|
    daemon_json_ok = capture("jq -e '.dns==[\"172.17.0.1\"] and .\"dns-search\"==[\".\"] and .\"dns-opts\"==[\"ndots:0\"]' /etc/docker/daemon.json >/dev/null 2>&1 && echo ok || true").strip == "ok"
    has_resolved = capture(resolved_unit_cmd).strip == "yes"
    unless has_resolved
      puts "[docker_resolved] systemd-resolved.service not found; checking docker daemon DNS config only" if Deploy.debug?
      next daemon_json_ok
    end
    enabled = capture("systemctl is-enabled systemd-resolved 2>/dev/null || true").strip == "enabled"
    active = capture("systemctl is-active systemd-resolved 2>/dev/null || true").strip == "active"
    conf_ok = capture("grep -q '^DNSStubListenerExtra=172\\.17\\.0\\.1' /etc/systemd/resolved.conf.d/docker.conf 2>/dev/null && echo ok || true").strip == "ok"
    netstat_ok = capture("netstat -lptn 2>/dev/null | grep -q '172\\.17\\.0\\.1' && echo ok || true").strip == "ok"
    daemon_json_ok && enabled && active && conf_ok && netstat_ok
  end

  apply do |_params|
    helper = File.expand_path('config.docker-resolved.sh', __dir__)
    unless File.exist?(helper)
      warn 'config.docker-resolved.sh not found; skipping'
      return
    end
    remote(File.read(helper))
    has_resolved = capture(resolved_unit_cmd).strip == "yes"
    unless has_resolved
      puts "[docker_resolved] systemd-resolved.service not found; skipping runtime validation"
      next
    end
    active = capture("systemctl is-active systemd-resolved 2>/dev/null || true").strip == "active"
    unless active
      puts "[docker_resolved] systemd-resolved is not active after apply; dumping status/logs"
      puts capture("systemctl status systemd-resolved --no-pager || true")
      puts capture("journalctl -u systemd-resolved --no-pager -n 50 || true")
      raise "systemd-resolved is not active"
    end
  end
end
