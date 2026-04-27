Action :grafana do
  apply { |_params| deploy_drs('grafana.drs') }
end
