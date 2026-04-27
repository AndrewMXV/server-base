Action :registry_listener do
  apply do |_params|
    remote "mkdir -p /root/.docker"
    deploy_drs %w[otlp.drs registry-listener.drs]
  end
end
