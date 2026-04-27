Action :base, default: true do
  UBUNTU_PACKAGES = %w[curl mc htop screen gdu swapspace rsync jq chrony].freeze
  REDOS_PACKAGES  = %w[curl mc htop screen ncdu rsync jq chrony].freeze
  FALLBACK_NTP_SERVERS = %w[
    0.ru.pool.ntp.org
    1.ru.pool.ntp.org
    2.ru.pool.ntp.org
    3.ru.pool.ntp.org
    ntp.sashenki.ru
    vniiftri.khv.ru
    time.cloudflare.com
    time.google.com
    0.pool.ntp.org
    1.pool.ntp.org
    2.pool.ntp.org
    3.pool.ntp.org
  ].freeze
  check do |params|
    skip = Array(params[:skip_packages]).map(&:to_s)
    skip_ruby = params[:skip_ruby] == true
    swap_cfg = params[:swapfile].is_a?(Hash) ? params[:swapfile] : nil
    manage_swapfile = if !swap_cfg.nil?
      swap_cfg.fetch(:manage, true) == true
    elsif params.key?(:manage_swapfile)
      params[:manage_swapfile] == true
    else
      !skip.include?('swapfile')
    end
    swapfile_size_gb = Integer(swap_cfg&.fetch(:size_gb, nil) || params[:swapfile_size_gb] || 16) rescue 16
    swapfile_size_bytes = swapfile_size_gb * 1024 * 1024 * 1024
    ntp_servers = Array(params[:ntp_servers]).flat_map { |v| v.to_s.split(/[\s,]+/) }.map(&:strip).reject(&:empty?).uniq
    pkgs = (distro == 'redos' ? REDOS_PACKAGES : UBUNTU_PACKAGES) - skip
    missing = pkgs.reject do |pkg|
      if distro == 'ubuntu'
        capture("dpkg -l | grep -qw #{pkg} && echo ok || true").strip == 'ok'
      else
        capture("rpm -q #{pkg} >/dev/null 2>&1 && echo ok || true").strip == 'ok'
      end
    end
    ruby_ok = true
    unless skip_ruby
      ruby_ok = capture('command -v ruby >/dev/null 2>&1 && ruby -e "exit(RUBY_VERSION.split(\'.\').first.to_i >= 3 ? 0 : 1)" >/dev/null 2>&1 && ruby -ropenssl -e "puts OpenSSL::OPENSSL_VERSION" >/dev/null 2>&1 && echo ok || true').strip == 'ok'
      if !ruby_ok
        ruby_ok = capture('RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"; if [ -x "$RBENV_ROOT/bin/rbenv" ]; then PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" command -v ruby >/dev/null 2>&1 && ruby -e "exit(RUBY_VERSION.split(\'.\').first.to_i >= 3 ? 0 : 1)" >/dev/null 2>&1 && ruby -ropenssl -e "puts OpenSSL::OPENSSL_VERSION" >/dev/null 2>&1 && echo ok || true; fi').strip == 'ok'
      end
    end
    ipvs_ok = capture('lsmod | grep -qw ip_vs && echo ok || true').strip == 'ok'
    chrony_active = true
    chrony_connected = true
    unless skip.include?('chrony')
      chrony_state = capture(<<~SH).strip
        set +e
        active=inactive
        connected=disconnected
        chrony_sources_snapshot() {
          tmp="$(mktemp)"
          chronyc sources -n >"$tmp" 2>/dev/null &
          pid=$!
          for _ in $(seq 1 5); do
            if ! kill -0 "$pid" 2>/dev/null; then
              wait "$pid"
              chrony_sources_status=$?
              chrony_sources_output="$(cat "$tmp" 2>/dev/null || true)"
              rm -f "$tmp"
              return 0
            fi
            sleep 1
          done
          kill "$pid" 2>/dev/null || true
          sleep 1
          kill -9 "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          chrony_sources_status=124
          chrony_sources_output="$(cat "$tmp" 2>/dev/null || true)"
          rm -f "$tmp"
        }
        if (systemctl is-active chronyd || systemctl is-active chrony) >/dev/null 2>&1; then
          active=active
        fi
        if [ "$active" = "active" ] && command -v chronyc >/dev/null 2>&1; then
          if chronyc tracking >/dev/null 2>&1; then
            chrony_sources_snapshot
          fi
          if [ "${chrony_sources_status:-1}" = 124 ] || ([ "${chrony_sources_status:-1}" = 0 ] && printf '%s\n' "$chrony_sources_output" | awk 'NR > 2 && length($1) >= 2 { st = substr($1, 2, 1); reach = $5 + 0; if (st == "*" || st == "+" || reach > 0) ok = 1 } END { exit ok ? 0 : 1 }'); then
            connected=connected
          fi
        fi
        printf '%s|%s\\n' "$active" "$connected"
      SH
      active_state, connected_state = chrony_state.split('|', 2)
      chrony_active = active_state == 'active'
      chrony_connected = connected_state == 'connected'
    end
    chrony_ok = chrony_active && chrony_connected
    yq_ok = skip.include?('yq') || capture('yq --version >/dev/null 2>&1 && echo ok || true').strip == 'ok'
    root_ps1_ok = capture(%q{grep -Fqx "export PS1='\u@\H:\w# '" /root/.bashrc && echo ok || true}).strip == 'ok'
    swap_present = capture('swapon --show=NAME --noheadings 2>/dev/null | tr -d " " | grep -qx /swapfile && echo ok || true').strip == 'ok'
    swap_size_ok = capture('test -f /swapfile && stat -c %s /swapfile || true').strip == swapfile_size_bytes.to_s
    swap_ok = !manage_swapfile || distro == 'ubuntu' || (swap_present && swap_size_ok)
    k8s_repo_absent = distro != 'redos' || capture('[ ! -f /etc/yum.repos.d/kubernetes.repo ] && echo ok || true').strip == 'ok'
    ok = ruby_ok && ipvs_ok && chrony_ok && yq_ok && root_ps1_ok && missing.empty? && swap_ok && k8s_repo_absent
    unless ok
      puts "[base check] missing packages: #{missing.join(', ')}" unless missing.empty?
      puts "[base check] ruby missing, < 3, or openssl extension unavailable" unless ruby_ok
      puts "[base check] ip_vs module missing" unless ipvs_ok
      puts "[base check] chrony not active" unless chrony_active
      puts "[base check] chrony is active but not synchronized to any source" if chrony_active && !chrony_connected
      puts "[base check] requested custom NTP servers: #{ntp_servers.join(', ')}" unless ntp_servers.empty?
      puts "[base check] yq missing" unless yq_ok
      puts "[base check] /root/.bashrc missing required PS1 export" unless root_ps1_ok
      if manage_swapfile && distro == 'redos' && !swap_ok
        puts "[base check] /swapfile missing or size mismatch (expected #{swapfile_size_gb}G)"
      end
      puts "[base check] kubernetes.repo present (will be removed)" unless k8s_repo_absent
    end
    ok
  end

  apply do |params|
    skip = Array(params[:skip_packages]).map(&:to_s)
    skip_ruby = params[:skip_ruby] == true
    swap_cfg = params[:swapfile].is_a?(Hash) ? params[:swapfile] : nil
    manage_swapfile = if !swap_cfg.nil?
      swap_cfg.fetch(:manage, true) == true
    elsif params.key?(:manage_swapfile)
      params[:manage_swapfile] == true
    else
      !skip.include?('swapfile')
    end
    swapfile_size_gb = Integer(swap_cfg&.fetch(:size_gb, nil) || params[:swapfile_size_gb] || 16) rescue 16
    ntp_servers = Array(params[:ntp_servers]).flat_map { |v| v.to_s.split(/[\s,]+/) }.map(&:strip).reject(&:empty?).uniq
    ntp_servers_shell = ntp_servers.map { |srv| Shellwords.escape(srv) }.join(' ')
    fallback_ntp_servers_shell = FALLBACK_NTP_SERVERS.map { |srv| Shellwords.escape(srv) }.join(' ')
    pkgs = (distro == 'redos' ? REDOS_PACKAGES : UBUNTU_PACKAGES) - skip
    ruby_install_script = File.read(File.join(__dir__, 'install_ruby.sh'))
    remote <<~SH
      set -euo pipefail
      DISTRO=#{distro}
      SKIP_PACKAGES="#{skip.join(' ')}"
      SKIP_RUBY=#{skip_ruby ? 1 : 0}
      MANAGE_SWAPFILE=#{manage_swapfile ? 1 : 0}
      SWAPFILE_SIZE_GB=#{swapfile_size_gb}
      NTP_SERVERS="#{ntp_servers_shell}"
      FALLBACK_NTP_SERVERS="#{fallback_ntp_servers_shell}"
      RUBY_INSTALL_SCRIPT=/tmp/base-install-ruby.sh
      cat > "$RUBY_INSTALL_SCRIPT" <<'RUBY_INSTALL'
#{ruby_install_script}
RUBY_INSTALL
      chmod +x "$RUBY_INSTALL_SCRIPT"
      skip_pkg() {
        for pkg in $SKIP_PACKAGES; do
          [ "$pkg" = "$1" ] && return 0
        done
        return 1
      }
      chrony_conf_file() {
        [ -f /etc/chrony/chrony.conf ] && { echo /etc/chrony/chrony.conf; return; }
        [ -f /etc/chrony.conf ] && { echo /etc/chrony.conf; return; }
        echo /etc/chrony.conf
      }
      configure_chrony_servers() {
        marker="$1"
        servers="$2"
        [ -n "$servers" ] || return 0
        conf="$(chrony_conf_file)"
        [ -f "$conf" ] || return 0
        begin="# BEGIN ${marker}"
        end="# END ${marker}"
        tmp="$(mktemp)"
        awk -v begin="$begin" -v end="$end" '
          $0 == begin { skip = 1; next }
          $0 == end { skip = 0; next }
          !skip { print }
        ' "$conf" > "$tmp"
        {
          cat "$tmp"
          echo "$begin"
          for srv in $servers; do
            echo "server $srv iburst"
          done
          echo "$end"
        } > "${tmp}.new"
        cat "${tmp}.new" > "$conf"
        rm -f "$tmp" "${tmp}.new"
      }
      chrony_daemon_ready() {
        command -v chronyc >/dev/null 2>&1 || return 1
        chronyc tracking >/dev/null 2>&1
      }
      chrony_sources_snapshot() {
        tmp="$(mktemp)"
        chronyc sources -n >"$tmp" 2>/dev/null &
        pid=$!
        for _ in $(seq 1 5); do
          if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            chrony_sources_status=$?
            chrony_sources_output="$(cat "$tmp" 2>/dev/null || true)"
            rm -f "$tmp"
            return 0
          fi
          sleep 1
        done
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        chrony_sources_status=124
        chrony_sources_output="$(cat "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"
      }
      chrony_connected() {
        (systemctl is-active chronyd || systemctl is-active chrony) >/dev/null 2>&1 || return 1
        chrony_daemon_ready || return 1
        chrony_sources_snapshot
        [ "${chrony_sources_status:-1}" = 124 ] && return 0
        [ "${chrony_sources_status:-1}" = 0 ] || return 1
        printf '%s\n' "$chrony_sources_output" | awk 'NR > 2 && length($1) >= 2 { st = substr($1, 2, 1); reach = $5 + 0; if (st == "*" || st == "+" || reach > 0) ok = 1 } END { exit ok ? 0 : 1 }'
      }
      chrony_sources_dead() {
        (systemctl is-active chronyd || systemctl is-active chrony) >/dev/null 2>&1 || return 1
        chrony_daemon_ready || return 1
        chrony_sources_snapshot
        [ "${chrony_sources_status:-1}" = 124 ] && return 1
        [ "${chrony_sources_status:-1}" = 0 ] || return 1
        printf '%s\n' "$chrony_sources_output" | awk '
          NR > 2 && length($1) >= 2 {
            seen = 1
            st = substr($1, 2, 1)
            reach = $5 + 0
            if (st == "*" || st == "+" || reach > 0) alive = 1
          }
          END { exit (seen && !alive) ? 0 : 1 }
        '
      }
      restart_chrony() {
        svc=''
        if systemctl enable chronyd >/dev/null 2>&1; then
          svc=chronyd
          systemctl restart chronyd || true
        elif systemctl enable chrony >/dev/null 2>&1; then
          svc=chrony
          systemctl restart chrony || true
        fi
      }
      wait_chrony_ready() {
        for _ in $(seq 1 20); do
          chrony_daemon_ready && return 0
          sleep 1
        done
        return 1
      }
      wait_chrony_sync() {
        chronyc burst 4/4 >/dev/null 2>&1 || true
        for _ in $(seq 1 60); do
          chrony_connected && return 0
          sleep 1
        done
        return 1
      }
      apply_fallback_chrony() {
        [ -n "$FALLBACK_NTP_SERVERS" ] || return 1
        [ "${chrony_fallback_applied:-0}" = 0 ] || return 1
        chrony_fallback_applied=1
        echo "[base] chrony current sources are not synchronized, trying fallback public NTP servers: $FALLBACK_NTP_SERVERS"
        configure_chrony_servers 'BASE FALLBACK NTP SERVERS' "$FALLBACK_NTP_SERVERS"
        restart_chrony
        wait_chrony_ready || true
        wait_chrony_sync
      }
      probe_chrony_sync() {
        chronyc burst 4/4 >/dev/null 2>&1 || true
        for _ in $(seq 1 5); do
          chrony_connected && return 0
          chrony_sources_dead && return 2
          sleep 1
        done
        return 1
      }
      update_once() {
        if [ "$DISTRO" = "ubuntu" ]; then
          if [ -z "${_APT_UPDATED:-}" ]; then
            apt-get update -y
            _APT_UPDATED=1
          fi
        elif [ "$DISTRO" = "redos" ]; then
          if [ -z "${_DNF_UPDATED:-}" ]; then
            dnf makecache --refresh -y || true
            _DNF_UPDATED=1
          fi
        fi
      }
      install_pkg() {
        pkg=$1
        if [ "$DISTRO" = "ubuntu" ]; then
          if ! dpkg -l | grep -qw "$pkg"; then
            update_once
            apt-get install -y "$pkg"
          fi
        elif [ "$DISTRO" = "redos" ]; then
          if ! rpm -q "$pkg" >/dev/null 2>&1; then
            update_once
            dnf install -y "$pkg"
          fi
        fi
      }
      for p in #{pkgs.join(" ")}; do
        install_pkg "$p"
      done
      if [ "$DISTRO" = "redos" ] && [ -f /etc/yum.repos.d/kubernetes.repo ]; then
        rm -f /etc/yum.repos.d/kubernetes.repo
      fi
      # ensure chrony is running
      if ! skip_pkg chrony; then
        configure_chrony_servers 'BASE NTP SERVERS' "$NTP_SERVERS"
        restart_chrony
        chrony_fallback_applied=0
        [ -z "$NTP_SERVERS" ] || echo "[base] configured custom NTP servers: $NTP_SERVERS"
        wait_chrony_ready || {
          echo "[base] chrony daemon is not ready for chronyc"
          if [ -n "${svc:-}" ]; then
            systemctl status "$svc" --no-pager -l || true
          fi
          chronyc tracking || true
          exit 1
        }
        if probe_chrony_sync; then
          probe_status=0
        else
          probe_status=$?
        fi
        if [ "$probe_status" = 2 ] && [ -n "$FALLBACK_NTP_SERVERS" ]; then
          echo "[base] chrony current sources look unreachable, switching to fallback public NTP servers"
          apply_fallback_chrony || true
        elif [ "$probe_status" != 0 ]; then
          wait_chrony_sync || true
        fi
        chrony_connected || apply_fallback_chrony || true
        chrony_connected || {
          echo "[base] chrony is active but not synchronized to any source"
          chronyc tracking || true
          chronyc sources -n || true
          exit 1
        }
      fi
      # install yq via upstream binary
      if ! skip_pkg yq && ! yq --version >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        chmod a+x /usr/local/bin/yq
      fi
      ruby_ok() {
        ruby -e 'exit(RUBY_VERSION.split(".").first.to_i >= 3 ? 0 : 1)' >/dev/null 2>&1 && \
          ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION' >/dev/null 2>&1
      }
      ruby_ok_bin() {
        local bin="$1"
        [ -x "$bin" ] || return 1
        "$bin" -e 'exit(RUBY_VERSION.split(".").first.to_i >= 3 ? 0 : 1)' >/dev/null 2>&1 && \
          "$bin" -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION' >/dev/null 2>&1
      }
      if [ "$SKIP_RUBY" != "1" ]; then
        if ! ruby_ok; then
          if [ "$DISTRO" = "ubuntu" ]; then
            update_once
            apt-get install -y ruby-full
          else
            # Prefer distro Ruby on RedOS to guarantee OpenSSL ABI compatibility (libssl.so.3).
            update_once
            dnf install -y ruby ruby-libs || true
            if ruby_ok_bin /usr/bin/ruby; then
              ln -sf /usr/bin/ruby /usr/local/bin/ruby
              [ -x /usr/bin/gem ] && ln -sf /usr/bin/gem /usr/local/bin/gem
              if [ -x /usr/bin/irb ]; then
                ln -sf /usr/bin/irb /usr/local/bin/irb
              else
                rm -f /usr/local/bin/irb
              fi
              if [ -x /usr/bin/bundle ]; then
                ln -sf /usr/bin/bundle /usr/local/bin/bundle
              else
                rm -f /usr/local/bin/bundle
              fi
            fi
          fi
        fi
        if ! ruby_ok && [ "$DISTRO" = "redos" ]; then
          # If /usr/local Ruby is incompatible, remove stale links and retry prebuilt installer.
          if [ -L /usr/local/bin/ruby ] && ! ruby_ok_bin /usr/local/bin/ruby; then
            rm -f /usr/local/bin/ruby /usr/local/bin/gem /usr/local/bin/irb /usr/local/bin/bundle
          fi
          if ! ruby_ok_bin /usr/bin/ruby; then
            ruby_installed=0
            for ruby_ver in 3.4.7 3.3.7 3.2.7 3.1.7; do
              echo "[base] trying Ruby ${ruby_ver}"
              if "$RUBY_INSTALL_SCRIPT" "$ruby_ver"; then
                ruby_installed=1
                break
              fi
              echo "[base] Ruby ${ruby_ver} install failed, trying next fallback"
            done
            [ "$ruby_installed" = 1 ] || {
              echo "[base] failed to install compatible Ruby 3.x"
              exit 1
            }
          fi
        fi
        ruby_ok || {
          echo "[base] ruby is installed but OpenSSL extension is unavailable"
          exit 1
        }
      else
        echo "[base] skip_ruby enabled: skipping Ruby/OpenSSL check and installation"
      fi
      if ! lsmod | grep -qw ip_vs; then
        modprobe ip_vs
      fi
      desired_ps1="export PS1='\\u@\\H:\\w# '"
      touch /root/.bashrc
      if ! grep -Fqx "$desired_ps1" /root/.bashrc; then
        if grep -qE '^export PS1=' /root/.bashrc; then
          sed -i "s|^export PS1=.*$|$desired_ps1|" /root/.bashrc
        else
          printf '\n%s\n' "$desired_ps1" >> /root/.bashrc
        fi
      fi
      if [ "$DISTRO" = "ubuntu" ]; then
        grep -qw ip_vs /etc/modules || echo ip_vs >> /etc/modules
      else
        grep -qw ip_vs /etc/modules-load.d/modules.conf || echo ip_vs >> /etc/modules-load.d/modules.conf
      fi

      if [ "$MANAGE_SWAPFILE" = "1" ] && [ "$DISTRO" = "redos" ]; then
        [ "$SWAPFILE_SIZE_GB" -gt 0 ] || {
          echo "[base] invalid swap size: $SWAPFILE_SIZE_GB"
          exit 1
        }
        target_bytes=$((SWAPFILE_SIZE_GB * 1024 * 1024 * 1024))
        current_bytes=0
        if [ -f /swapfile ]; then
          current_bytes="$(stat -c %s /swapfile)"
        fi
        if [ "$current_bytes" -ne "$target_bytes" ]; then
          swapon --show=NAME --noheadings 2>/dev/null | tr -d ' ' | grep -qx /swapfile && swapoff /swapfile
          rm -f /swapfile
          fallocate -l "${SWAPFILE_SIZE_GB}G" /swapfile
          chmod 600 /swapfile
          mkswap /swapfile
          echo "[base] /swapfile resized to ${SWAPFILE_SIZE_GB}G"
        fi
        if ! swapon --show=NAME --noheadings 2>/dev/null | tr -d ' ' | grep -qx /swapfile; then
          swapon /swapfile
        fi
        grep -vE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab > /etc/fstab.tmp || true
        echo '/swapfile none swap sw 0 0' >> /etc/fstab.tmp
        mv /etc/fstab.tmp /etc/fstab
        swapon --show
        free -h
      fi
    SH
  end
end
