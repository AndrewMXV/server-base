Server :demo do
  host '203.0.113.10'
  main_domain 'demo.example.com'
  # tls_domain 'demo.example.com'

  install :swarm
  install :traefik
  install :oauth2_slim
  install :insight
  install :grafana
  install :registry_listener
end
