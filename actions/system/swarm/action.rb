Action :swarm, depends: [:docker] do
  check do |_params|
    swarm_active = capture("docker info 2>/dev/null | grep -q 'Swarm: active' && echo ok || true").strip == 'ok'
    loki_installed = capture("docker plugin ls 2>/dev/null | grep -q 'loki:latest' && echo ok || true").strip == 'ok'
    ingress_network = capture("docker network ls --format '{{.Name}}' 2>/dev/null | grep -q 'ingress-routing' && echo ok || true").strip == 'ok'
    grafana_network = capture("docker network ls --format '{{.Name}}' 2>/dev/null | grep -q 'grafana-network' && echo ok || true").strip == 'ok'
    nats_network = capture("docker network ls --format '{{.Name}}' 2>/dev/null | grep -q 'nats-network' && echo ok || true").strip == 'ok'

    swarm_active && loki_installed && ingress_network && grafana_network && nats_network
  end

  apply do |params|
    join_token = nil
    manager_ip = params[:manager_ip]
    advertise_addr = params[:advertise_addr]
    # if manager_ip && !manager_ip.empty?
    #   join_token = `ssh -o StrictHostKeyChecking=no #{manager_ip} docker swarm join-token -q worker`.strip
    # end
    script = <<~SH
      set -euo pipefail

      pick_advertise_addr() {
        local given="#{advertise_addr}"
        if [ -n "$given" ]; then
          echo "$given"
          return 0
        fi

        local ips private_ip
        ips="$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 || true)"
        private_ip="$(printf '%s\n' "$ips" | awk '/^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.)/{print; exit}' || true)"
        if [ -n "$private_ip" ]; then
          echo "$private_ip"
          return 0
        fi

        printf '%s\n' "$ips" | head -n 1
      }

      if ! docker plugin ls | grep -q "loki:latest"; then
          echo "Installing Grafana Loki Docker driver plugin..."
          docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions
      #    docker plugin disable loki --force
      #    docker plugin upgrade loki grafana/loki-docker-driver:latest --alias loki --grant-all-permissions
      #    docker plugin enable loki
      #    sudo systemctl restart docker
      else
          echo "Grafana Loki Docker driver plugin is already installed."
      fi

      if docker info 2>/dev/null | grep -q 'Swarm: active'; then
        echo "Swarm already active"
      else
        if [ -n "#{join_token}" ]; then
          echo "Joining Swarm master: #{manager_ip}:2377"
          docker swarm join --token "#{join_token}" #{manager_ip}:2377
        else
          advertise_addr="$(pick_advertise_addr)"
          if [ -z "$advertise_addr" ]; then
            echo "Failed to auto-detect advertise address for swarm init" >&2
            exit 1
          fi
          echo "Initialize Swarm master"
          echo "Using advertise address: $advertise_addr"
          docker swarm init --advertise-addr "$advertise_addr"
        fi
      fi

      if [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" = "true" ]; then
          # Check if the network already exists
          if ! docker network ls --format '{{.Name}}' | grep -q "ingress-routing"; then
              echo "Creating ingress-routing network..."
              docker network create --driver overlay ingress-routing
          else
              echo "ingress-routing network already exists."
          fi
      
          # Check if the network already exists
          if ! docker network ls --format '{{.Name}}' | grep -q "grafana-network"; then
              echo "Creating grafana-network network..."
              docker network create --driver overlay grafana-network
          else
              echo "grafana-network network already exists."
          fi
      
          # Check if the network already exists
          if ! docker network ls --format '{{.Name}}' | grep -q "nats-network"; then
              echo "Creating nats-network network..."
              docker network create --driver overlay nats-network
          else
              echo "nats-network network already exists."
          fi
      else
          echo "This is a worker node. Skipping network creation."
      fi
    SH
    remote(script)
  end
end
