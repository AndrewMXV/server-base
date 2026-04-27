Action :oauth2_slim do
  apply { |_params| deploy_drs('oauth2_slim.drs') }
end
