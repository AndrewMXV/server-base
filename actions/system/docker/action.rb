require 'json'

docker_running = ->(ctx) { ctx.capture('docker info >/dev/null 2>&1 && echo ok || true').strip == 'ok' }

Action :docker do
  check do |_params|
    bin_ok = capture('docker --version >/dev/null 2>&1 && echo ok || true').strip == 'ok'
    bin_ok && docker_running[self]
  end

  apply do |params|
    type = params[:type]&.to_s
    version = params[:version]

    if version && type != 'static'
      raise 'docker :version is supported only with type: :static'
    end

    if type == 'static'
      if version && version.to_s !~ /\A[0-9]+(\.[0-9]+){0,3}\z/
        raise "docker static version must be digits and dots: #{version}"
      end

      script_path = File.expand_path('install-docker-static.sh', __dir__)
      unless File.file?(script_path)
        warn "install-docker-static.sh not found at #{script_path}; skipping"
        return
      end

      version_arg = version ? " #{version}" : ''
      install_script = File.read(script_path)
      write_file('/tmp/install-docker-static', install_script)
      exec('chmod +x /tmp/install-docker-static')
      exec("/tmp/install-docker-static#{version_arg}")
      exec('rm -f /tmp/install-docker-static')
    else
      script = <<~SH
        set -euo pipefail
        DISTRO=#{distro}
        if [ "$DISTRO" = "ubuntu" ]; then
          apt-get update -y
          apt-get install -y ca-certificates curl gnupg
          install -m 0755 -d /etc/apt/keyrings
          if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
          fi
          if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
          fi
          apt-get update -y
          # docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
          apt-get install -y docker-ce
        elif [ "$DISTRO" = "redos" ]; then
          dnf install -y ca-certificates curl gnupg2
          if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            dnf makecache -y
          fi
          dnf install -y docker-ce
        fi
      SH
      remote(script)
    end

    json_path = '/etc/docker/daemon.json'
    raw = read_file(json_path, default: '{}').to_s
    data = JSON raw rescue nil
    data = {} unless data.is_a?(Hash)

    deep_merge = lambda do |base, override|
      merged = base.dup
      override.each do |key, value|
        if merged[key].is_a?(Hash) && value.is_a?(Hash)
          merged[key] = deep_merge.call(merged[key], value)
        else
          merged[key] = value
        end
      end
      merged
    end

    defaults = {
      'features' => { 'buildkit' => true },
      'log-driver' => 'json-file',
      'log-opts' => { 'max-size' => '250m', 'max-file' => '3' },
      'live-restore' => false
    }
    merged = deep_merge.call(data, defaults)

    systemd = capture('if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then echo yes; else echo no; fi').strip == 'yes'
    exec('systemctl enable docker') if systemd

    if merged != data
      write_file(json_path, JSON.pretty_generate(merged))
      exec('systemctl restart docker') if systemd
    end

    if systemd
      exec <<~SH
        set -e
        if systemctl list-unit-files | grep -q '^docker\\.service'; then
          if [ "$(systemctl is-enabled docker.service 2>/dev/null || true)" = "masked" ]; then
            systemctl unmask docker.service docker.socket || true
            systemctl daemon-reload || true
          fi
          systemctl enable docker.socket docker.service || true
          systemctl restart docker || systemctl start docker
        fi
      SH
    end

    exec <<~SH
      set -e
      install -d -m 700 /root/.docker
      [ -f /root/.docker/config.json ] || printf '{}\n' > /root/.docker/config.json
      chmod 600 /root/.docker/config.json
    SH

    unless docker_running[self]
      puts '[docker] daemon is not reachable after apply; dumping status/logs'
      if systemd
        puts capture('systemctl status docker --no-pager || true')
        puts capture('journalctl -u docker --no-pager -n 80 || true')
      end
      raise 'docker daemon is not running'
    end
  end
end
#
