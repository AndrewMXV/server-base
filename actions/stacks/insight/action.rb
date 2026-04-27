Action :insight do
  apply { |_params| deploy_drs %w[otlp.drs insight.drs] }
end
