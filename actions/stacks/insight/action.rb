Action :insight do
  apply do |_params|
    remote "mkdir -p /root/.docker && [ -f /root/.docker/config.json ] || echo '{}' > /root/.docker/config.json"
    deploy_drs %w[otlp.drs insight.drs]
  end
end
