Server :simple_stack do
  host '<change_ip>'
  tls_domain '<change_domain>'

  install :swarm
  install :traefik
  install :oauth2_slim
  install :insight
  install :grafana
  install :registry_listener

  env AUTH_BOT: 'eksli_auth_bot'
  env AUTH_VERIFY_KEY: '<change_me>'
  env MAIN_DOMAIN: '<change_domain>'
  env FORWARD_OAUTH_AUTH_URL: '/oauth_slim/authorize'
  env CONSOLE_LEVEL: 'all'

  env INSIGHT_BASIC_AUTH: 'admin:admin'

  env USERS_YAML: '/users.yaml'
  config target: '/users.yaml', file_content: <<~YAML
    users:
      - admin: { Name: Fullname, role: admin, org: eksli, enabled: true, password: admin }  
      # - admin: { Name: Fullname, role: admin, org: eksli, enabled: true, password: admin }  
  YAML
end