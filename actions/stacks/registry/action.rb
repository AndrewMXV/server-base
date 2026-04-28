Action :registry do
  apply do |_params|
    deploy_drs 'registry.drs'
  end
end
