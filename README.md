# Server Base

Small Ruby deployment tool for provisioning a Docker Swarm host over SSH and
deploying a basic public infrastructure stack.

Included actions:

- `swarm`
- `traefik`
- `oauth2_slim`
- `insight`
- `grafana`
- `registry_listener`

The runtime also includes the default/dependency actions needed by those
install steps: `base`, `docker`, `docker_resolved`, and `system_check`.

## Requirements

- Ruby 3+
- root SSH access to the target server
- Docker-capable Ubuntu or RED OS target
- `dry-stack` available locally through Bundler

Install dependencies:

```sh
bundle install
```

## Demo Server

Edit `config/servers/demo.rb` and replace the example host/domain values.

Run:

```sh
ruby bin/deploy --server demo
```

Or use the interactive server picker:

```sh
ruby bin/deploy-menu
```

The deploy CLI loads `config/servers/demo.rb`, resolves action dependencies,
runs remote checks, and applies only the actions that are not already satisfied.

## CI/CD

The repository includes a GitLab CI deploy pipeline. Configure `SSH_PRIVATE_KEY`
as a masked CI variable, then run either the default deploy job or the manual
`deploy-demo` job.

Local Docker smoke test:

```sh
./test-deploy-dockerfile.sh config/servers demo
```

## Useful Environment Variables

- `GF_ADMIN_PASSWORD`: Grafana admin password. Defaults to `admin`.
- `TRAEFIK_BASIC_AUTH`: optional Traefik/diagnostic basic auth value used by
  dry-stack ingress rules.
- `ACME_EMAIL`: ACME registration email when TLS is enabled.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: optional registry listener and
  Grafana alert notifications.
- `AUTH_VERIFY_KEY`: optional `oauth2_slim` verify key.

Do not commit real server IPs, credentials, generated dry-stack config files, or
local `.env` files to a public repository.
