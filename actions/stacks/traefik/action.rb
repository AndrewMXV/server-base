Action :traefik do
  apply { |_params| deploy_drs('ingress.drs') }
end
