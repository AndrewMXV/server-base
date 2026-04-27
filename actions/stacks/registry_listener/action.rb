Action :registry_listener do
  apply { |_params| deploy_drs %w[otlp.drs registry-listener.drs] }
end
