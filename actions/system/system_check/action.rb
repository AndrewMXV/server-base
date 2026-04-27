require 'json'

docker_daemon_path = '/etc/docker/daemon.json'
resolv_search_cmd = "grep -E '^search\\s+' /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null || true"
dns_config = { 'dns' => ['172.17.0.1'], 'dns-search' => ["."], 'dns-opts' => ['ndots:0'] }.freeze

read_daemon = ->(ctx) { JSON ctx.read_file(docker_daemon_path, default: '{}') rescue nil }
search_found = ->(ctx) { !ctx.capture(resolv_search_cmd).strip.empty? }
dns_ok = ->(data) { dns_config.all? { |k, v| Array(data[k]) == v } }

Action :system_check, default: true, depends: [:docker] do
  check do |_params|
    data = read_daemon[self]
    return false unless data

    icc_ok = data['icc'] != false

    return icc_ok unless search_found[self]

    icc_ok && dns_ok[data]
  end

  apply do |_params|
    data = read_daemon[self] || {}

    icc_fix = data['icc'] == false
    dns_fix = search_found[self] && !dns_ok[data]

    changes = {}
    changes['icc'] = true if icc_fix
    changes.merge!(dns_config) if dns_fix
    return if changes.empty?

    data.merge! changes

    write_file docker_daemon_path, JSON.pretty_generate(data)
    exec 'systemctl restart docker'
  end
end
