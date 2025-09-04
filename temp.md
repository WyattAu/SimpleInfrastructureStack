Of course. Here is the complete and final listing of every file for your infrastructure-as-code repository, with its full path specified.

---

### **`/ (Git Repository Root)`**

#### **`.github/workflows/ci.yml`**
```yaml
# Location: /.github/workflows/ci.yml

name: CI Configuration Validation

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

jobs:
  validate-infrastructure:
    name: Validate Docker Compose & YAML Configuration
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Lint YAML Files
        uses: ibiqlik/action-yamllint@v3
        with:
          file_or_dir: "."
          config_file: ".yamllint.yml"
          strict: true

      - name: Install Docker Compose
        run: |
          sudo apt-get update
          sudo apt-get install -y docker-compose

      - name: Aggregate .env.example Files for Validation
        run: |
          echo "Preparing a unified .env file from all .env.example files..."
          # This command finds all .env.example files, concatenates them,
          # sorts them, and removes duplicates, creating a clean .env file for testing.
          find . -name '.env.example' -exec cat {} + | sort -u > .env
          echo "Dummy .env file created."
          # Add a placeholder for the outpost token which is not in any example file
          # This is necessary because the token is generated manually post-deployment.
          echo "AUTHENTIK_OUTPOST_TOKEN=placeholder_for_ci_check" >> .env
          echo "File Contents:"
          cat .env

      - name: Validate All Docker Compose Files
        run: |
          # This script iterates through each directory containing a docker-compose.yml
          # and runs the 'config' command, which is the ultimate syntax and variable check.
          # The script will fail if any of the compose files are invalid.
          for dir in $(find . -name 'docker-compose.yml' -exec dirname {} \;); do
            echo "Validating Docker Compose in directory: $dir"
            docker-compose -f "$dir/docker-compose.yml" --env-file ./.env config > /dev/null
            if [ $? -ne 0 ]; then
              echo "::error::Validation failed for Docker Compose file in $dir"
              exit 1
            fi
            echo "✅ Validation successful for $dir"
          done

      - name: All Checks Passed
        run: echo "🎉 All infrastructure configuration files are valid."
```

#### **`.yamllint.yml`**
```yaml
# Location: /.yamllint.yml

# Stricter configuration for the YAML linter
extends: default
rules:
  line-length:
    max: 120
  indentation:
    spaces: 2
    indent-sequences: consistent
    check-multi-line-strings: true
  truthy:
    allowed-values: ['true', 'false']
```

---

### **`proxy/`**

#### **`proxy/.env.example`**

```dotenv
# Location: /proxy/.env.example

# --- GLOBAL SETTINGS (Required by multiple stacks) ---
DOMAIN=your-domain.com
ACME_EMAIL=your-acme-ssl-email@your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata

# --- DOCKER IMAGE VERSIONS ---
VERSION_TRAEFIK=v2.11
VERSION_CLOUDFLARE_DDNS=1.10.0

# --- SUBDOMAINS (For Traefik and DDNS) ---
SUBDOMAIN_TRAEFIK=traefik
SUBDOMAIN_AUTH=auth
SUBDOMAIN_GRAFANA=grafana
SUBDOMAIN_STATUS=status
SUBDOMAIN_GITEA=gitea
SUBDOMAIN_WOODPECKER=ci
SUBDOMAIN_TAIGA=taiga
SUBDOMAIN_MATRIX=matrix
SUBDOMAIN_HOMEPAGE=dashboard
SUBDOMAIN_DOCS_INTERNAL=docs-internal
SUBDOMAIN_DOCS_EXTERNAL=docs

# --- CLOUDFLARE CREDENTIALS ---
CF_API_TOKEN=!!!_YOUR_CLOUDFLARE_API_TOKEN_WITH_DNS_EDIT_PERMS_!!!
```

#### **`proxy/docker-compose.yml`**
```yaml
# Location: /proxy/docker-compose.yml

version: '3.8'

services:
  traefik:
    image: traefik:${VERSION_TRAEFIK}
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - traefik-public # Connects to the outside world and exposed services
    ports:
      - "80:80"
      - "443:443"
      - "8448:8448" # For Matrix Federation
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro # Read-only for security
      - ./config:/etc/traefik:ro # Configuration is read-only
      - ${APPDATA_PATH}/proxy/certs:/letsencrypt # Volume for SSL certs
    environment:
      - CF_API_TOKEN=${CF_API_TOKEN}
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - "traefik.enable=true"
      # --- Traefik Dashboard ---
      - "traefik.http.routers.traefik-dashboard.rule=Host(`${SUBDOMAIN_TRAEFIK}.${DOMAIN}`)"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.tls=true"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=cloudflare"
      - "traefik.http.routers.traefik-dashboard.middlewares=authentik@docker" # Secured by Authentik
      # --- Authentik Forward Auth Middleware Definition ---
      # This middleware is defined here but used by other services to protect them.
      - "traefik.http.middlewares.authentik.forwardauth.address=http://authentik-proxy:9000/outpost.goauthentik.io/auth/traefik"
      - "traefik.http.middlewares.authentik.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.authentik.forwardauth.authResponseHeaders=X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"

  cloudflare-ddns:
    image: favonia/cloudflare-ddns:${VERSION_CLOUDFLARE_DDNS}
    container_name: cloudflare-ddns
    restart: unless-stopped
    environment:
      - API_KEY=${CF_API_TOKEN}
      - ZONE=${DOMAIN}
      # Comma-separated list of all subdomains to manage
      - SUBDOMAINS=${SUBDOMAIN_TRAEFIK},${SUBDOMAIN_AUTH},${SUBDOMAIN_GRAFANA},${SUBDOMAIN_STATUS},${SUBDOMAIN_GITEA},${SUBDOMAIN_WOODPECKER},${SUBDOMAIN_TAIGA},${SUBDOMAIN_MATRIX},${SUBDOMAIN_HOMEPAGE},${SUBDOMAIN_DOCS_INTERNAL},${SUBDOMAIN_DOCS_EXTERNAL}
      - PROXIED=true
      - TTL=1 # Auto TTL

networks:
  traefik-public:
    external: true
```

#### **`proxy/config/traefik.yml`**
```yaml
# Location: /proxy/config/traefik.yml

global:
  checkNewVersion: true
  sendAnonymousUsage: false

log:
  level: INFO # Change to DEBUG for troubleshooting

api:
  dashboard: true

entryPoints:
  http:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: https
          scheme: https
  https:
    address: ":443"
  matrix:
    address: ":8448"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /etc/traefik
    watch: true

certificatesResolvers:
  cloudflare:
    acme:
      email: ${ACME_EMAIL}
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare
```

#### **`proxy/config/dynamic.yml`**
```yaml
# Location: /proxy/config/dynamic.yml

# This file contains routing rules not handled by Docker labels,
# specifically for Matrix Federation which requires a TCP router.

tcp:
  routers:
    matrix:
      rule: "HostSNI(`*`)"
      entryPoints:
        - "matrix"
      service: "matrix-synapse"
      tls: {}

  services:
    matrix-synapse:
      loadBalancer:
        servers:
          - address: "matrix-synapse:8448"
```

---

### **`iam/`**

#### **`iam/.env.example`**
```dotenv
# Location: /iam/.env.example

# --- GLOBAL SETTINGS ---
DOMAIN=your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata

# --- DOCKER IMAGE VERSIONS ---
VERSION_POSTGRES=16-alpine
VERSION_REDIS=7-alpine
VERSION_AUTHENTIK=2024.2.2

# --- SUBDOMAINS ---
SUBDOMAIN_AUTH=auth

# --- DATABASE CREDENTIALS ---
POSTGRES_USER=postgres
AUTHENTIK_DB_PASS=!!!_GENERATE_A_STRONG_AND_UNIQUE_PASSWORD_!!!

# --- AUTHENTIK CREDENTIALS & SECRETS ---
AUTHENTIK_SECRET_KEY=!!!_GENERATE_A_RANDOM_SECRET_KEY_WITH_OPENSSL_!!!
AUTHENTIK_BOOTSTRAP_PASSWORD=!!!_GENERATE_A_STRONG_PASSWORD_FOR_AKADMIN_!!!
# This value is NOT generated in advance. It is obtained from the Authentik UI
# after the initial deployment and outpost creation. A placeholder is needed for CI.
# AUTHENTIK_OUTPOST_TOKEN=
```

#### **`iam/docker-compose.yml`**
```yaml
# Location: /iam/docker-compose.yml

version: '3.8'

services:
  database:
    image: postgres:${VERSION_POSTGRES}
    container_name: authentik-db
    restart: unless-stopped
    networks:
      - shared-internal-net # Internal only
    volumes:
      - ${APPDATA_PATH}/iam/db:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${AUTHENTIK_DB_PASS}
      - POSTGRES_DB=authentik
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authentik -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 2G

  redis:
    image: redis:${VERSION_REDIS}
    container_name: authentik-redis
    restart: unless-stopped
    networks:
      - shared-internal-net # Internal only
    volumes:
      - ${APPDATA_PATH}/iam/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M

  server:
    image: ghcr.io/goauthentik/server:${VERSION_AUTHENTIK}
    container_name: authentik-server
    restart: unless-stopped
    networks:
      - shared-internal-net # Internal only
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ${APPDATA_PATH}/iam/media:/media
      - ${APPDATA_PATH}/iam/templates:/templates
    environment:
      - AUTHENTIK_REDIS__HOST=redis
      - AUTHENTIK_POSTGRESQL__HOST=database
      - AUTHENTIK_POSTGRESQL__USER=${POSTGRES_USER}
      - AUTHENTIK_POSTGRESQL__NAME=authentik
      - AUTHENTIK_POSTGRESQL__PASSWORD=${AUTHENTIK_DB_PASS}
      - AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}
    command: server

  worker:
    image: ghcr.io/goauthentik/server:${VERSION_AUTHENTIK}
    container_name: authentik-worker
    restart: unless-stopped
    networks:
      - shared-internal-net # Internal only
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ${APPDATA_PATH}/iam/media:/media
      - ${APPDATA_PATH}/iam/templates:/templates
    environment:
      - AUTHENTIK_REDIS__HOST=redis
      - AUTHENTIK_POSTGRESQL__HOST=database
      - AUTHENTIK_POSTGRESQL__USER=${POSTGRES_USER}
      - AUTHENTIK_POSTGRESQL__NAME=authentik
      - AUTHENTIK_POSTGRESQL__PASSWORD=${AUTHENTIK_DB_PASS}
      - AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}
    command: worker

  proxy:
    image: ghcr.io/goauthentik/proxy:${VERSION_AUTHENTIK}
    container_name: authentik-proxy
    restart: unless-stopped
    networks:
      - shared-internal-net
      - traefik-public # Exposed to Traefik
    environment:
      # !!! IMPORTANT !!!
      # The AUTHENTIK_TOKEN must be obtained from the Authentik UI after creating the outpost.
      # This is a manual step that must be performed after the initial deployment.
      - AUTHENTIK_HOST=http://authentik-server:9000
      - AUTHENTIK_TOKEN=${AUTHENTIK_OUTPOST_TOKEN}
      - AUTHENTIK_INSECURE=true
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authentik.rule=Host(`${SUBDOMAIN_AUTH}.${DOMAIN}`)"
      - "traefik.http.routers.authentik.tls=true"
      - "traefik.http.routers.authentik.tls.certresolver=cloudflare"
      - "traefik.http.services.authentik.loadbalancer.server.port=9000"

networks:
  traefik-public:
    external: true
  shared-internal-net:
    external: true
```

---

### **`monitoring/`**

#### **`monitoring/.env.example`**
```dotenv
# Location: /monitoring/.env.example

# --- GLOBAL SETTINGS ---
DOMAIN=your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata
SUBDOMAIN_AUTH=auth

# --- DOCKER IMAGE VERSIONS ---
VERSION_PROMETHEUS=v2.51.1
VERSION_CADVISOR=v0.47.2
VERSION_GRAFANA=10.4.1
VERSION_LOKI=2.9.7
VERSION_PROMTAIL=2.9.7
VERSION_UPTIME_KUMA=1

# --- SUBDOMAINS ---
SUBDOMAIN_GRAFANA=grafana
SUBDOMAIN_STATUS=status

# --- GRAFANA SECRETS ---
GRAFANA_ADMIN_PASSWORD=!!!_GENERATE_A_STRONG_GRAFANA_PASSWORD_!!!
# These values must be obtained after creating an OIDC provider for Grafana in the Authentik UI
GRAFANA_OAUTH_CLIENT_ID=!!!_YOUR_GRAFANA_CLIENT_ID_FROM_AUTHENTIK_!!!
GRAFANA_OAUTH_CLIENT_SECRET=!!!_YOUR_GRAFANA_CLIENT_SECRET_FROM_AUTHENTIK_!!!
```

#### **`monitoring/docker-compose.yml`**
```yaml
# Location: /monitoring/docker-compose.yml

version: '3.8'

services:
  prometheus:
    image: prom/prometheus:${VERSION_PROMETHEUS}
    container_name: prometheus
    restart: unless-stopped
    networks:
      - shared-internal-net
    volumes:
      - ${APPDATA_PATH}/monitoring/prometheus_data:/prometheus
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.enable-lifecycle'

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:${VERSION_CADVISOR}
    container_name: cadvisor
    restart: unless-stopped
    privileged: true # Required for cAdvisor to access host metrics
    networks:
      - shared-internal-net
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro

  grafana:
    image: grafana/grafana:${VERSION_GRAFANA}
    container_name: grafana
    restart: unless-stopped
    networks:
      - shared-internal-net
      - traefik-public
    volumes:
      - ${APPDATA_PATH}/monitoring/grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_AUTH_GENERIC_OAUTH_ENABLED=true
      - GF_AUTH_GENERIC_OAUTH_NAME=Authentik
      - GF_AUTH_GENERIC_OAUTH_CLIENT_ID=${GRAFANA_OAUTH_CLIENT_ID}
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${GRAFANA_OAUTH_CLIENT_SECRET}
      - GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email groups
      - GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://${SUBDOMAIN_AUTH}.${DOMAIN}/application/o/authorize/
      - GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://${SUBDOMAIN_AUTH}.${DOMAIN}/application/o/token/
      - GF_AUTH_GENERIC_OAUTH_API_URL=https://${SUBDOMAIN_AUTH}.${DOMAIN}/application/o/userinfo/
      - GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`${SUBDOMAIN_GRAFANA}.${DOMAIN}`)"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.routers.grafana.tls.certresolver=cloudflare"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"
      # Grafana is NOT protected by forward auth. It has its own robust OIDC integration.

  loki:
    image: grafana/loki:${VERSION_LOKI}
    container_name: loki
    restart: unless-stopped
    networks:
      - shared-internal-net
    volumes:
      - ${APPDATA_PATH}/monitoring/loki_data:/loki
      - ./config/loki-config.yml:/etc/loki/config.yml:ro
    command: -config.file=/etc/loki/config.yml

  promtail:
    image: grafana/promtail:${VERSION_PROMTAIL}
    container_name: promtail
    restart: unless-stopped
    networks:
      - shared-internal-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/promtail-config.yml:/etc/promtail/config.yml:ro
    command: -config.file=/etc/promtail/config.yml

  uptime-kuma:
    image: louislam/uptime-kuma:${VERSION_UPTIME_KUMA}
    container_name: uptime-kuma
    restart: unless-stopped
    networks:
      - traefik-public
    volumes:
      - ${APPDATA_PATH}/monitoring/uptime_kuma_data:/app/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime-kuma.rule=Host(`${SUBDOMAIN_STATUS}.${DOMAIN}`)"
      - "traefik.http.routers.uptime-kuma.tls=true"
      - "traefik.http.routers.uptime-kuma.tls.certresolver=cloudflare"
      - "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
      - "traefik.http.routers.uptime-kuma.middlewares=authentik@docker"

networks:
  traefik-public:
    external: true
  shared-internal-net:
    external: true
```

#### **`monitoring/config/prometheus.yml`**
```yaml
# Location: /monitoring/config/prometheus.yml

global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
```

#### **`monitoring/config/loki-config.yml`**
```yaml
# Location: /monitoring/config/loki-config.yml

auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 1m
schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
storage_config:
  boltdb_shipper:
    active_index_directory: /loki/boltdb-shipper-active
    cache_location: /loki/boltdb-shipper-cache
    cache_ttl: 24h
    shared_store: filesystem
  filesystem:
    directory: /loki/chunks
```

#### **`monitoring/config/promtail-config.yml`**
```yaml
# Location: /monitoring/config/promtail-config.yml

server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
- job_name: containers
  docker_sd_configs:
    - host: unix:///var/run/docker.sock
  relabel_configs:
    - source_labels: ['__meta_docker_container_name']
      regex: '/(.*)'
      target_label: 'container'
```

---

### **`dev/`**

#### **`dev/.env.example`**
```dotenv
# Location: /dev/.env.example

# --- GLOBAL SETTINGS ---
DOMAIN=your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata
POSTGRES_USER=postgres

# --- DOCKER IMAGE VERSIONS ---
VERSION_POSTGRES=16-alpine
VERSION_GITEA=1.21-rootless
VERSION_WOODPECKER_SERVER=v2.4.0
VERSION_WOODPECKER_AGENT=v2.4.0

# --- SUBDOMAINS ---
SUBDOMAIN_GITEA=gitea
SUBDOMAIN_WOODPECKER=ci

# --- DATABASE CREDENTIALS ---
GITEA_DB_PASS=!!!_GENERATE_A_STRONG_AND_UNIQUE_PASSWORD_!!!

# --- GITEA & WOODPECKER SECRETS ---
WOODPECKER_ADMIN_USER=YourGiteaAdminUsername
# These values must be obtained after creating an OAuth Application for Woodpecker in the Gitea UI
WOODPECKER_GITEA_CLIENT_ID=!!!_YOUR_GITEA_OAUTH_CLIENT_ID_!!!
WOODPECKER_GITEA_CLIENT_SECRET=!!!_YOUR_GITEA_OAUTH_CLIENT_SECRET_!!!
# Secret shared between Woodpecker server and agents.
WOODPECKER_AGENT_SECRET=!!!_GENERATE_A_RANDOM_AGENT_SECRET_!!!
```

#### **`dev/docker-compose.yml`**
```yaml
# Location: /dev/docker-compose.yml

version: '3.8'

services:
  database:
    image: postgres:${VERSION_POSTGRES}
    container_name: gitea-db
    restart: unless-stopped
    networks:
      - shared-internal-net
    volumes:
      - ${APPDATA_PATH}/dev/gitea-db:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${GITEA_DB_PASS}
      - POSTGRES_DB=gitea
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d gitea -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: gitea/gitea:${VERSION_GITEA}
    container_name: gitea
    user: "1000:1000" # Run as non-root
    restart: unless-stopped
    networks:
      - shared-internal-net
      - traefik-public
    depends_on:
      database:
        condition: service_healthy
    volumes:
      - ${APPDATA_PATH}/dev/gitea_data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=database:5432
      - GITEA__database__NAME=gitea
      - GITEA__database__USER=${POSTGRES_USER}
      - GITEA__database__PASSWD=${GITEA_DB_PASS}
      - GITEA__server__ROOT_URL=https://${SUBDOMAIN_GITEA}.${DOMAIN}
      # Further OIDC configuration will be done in Gitea's app.ini after first run
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.gitea.rule=Host(`${SUBDOMAIN_GITEA}.${DOMAIN}`)"
      - "traefik.http.routers.gitea.tls=true"
      - "traefik.http.routers.gitea.tls.certresolver=cloudflare"
      - "traefik.http.services.gitea.loadbalancer.server.port=3000"
      # Gitea has its own OIDC integration, so it's not protected by forward auth

  woodpecker-server:
    image: woodpeckerci/woodpecker-server:${VERSION_WOODPECKER_SERVER}
    container_name: woodpecker-server
    restart: unless-stopped
    networks:
      - shared-internal-net
      - traefik-public
    volumes:
      - ${APPDATA_PATH}/dev/woodpecker_data:/var/lib/woodpecker/
    environment:
      - WOODPECKER_HOST=https://${SUBDOMAIN_WOODPECKER}.${DOMAIN}
      - WOODPECKER_GITEA=true
      - WOODPECKER_GITEA_URL=https://${SUBDOMAIN_GITEA}.${DOMAIN}
      - WOODPECKER_GITEA_CLIENT=${WOODPECKER_GITEA_CLIENT_ID}
      - WOODPECKER_GITEA_SECRET=${WOODPECKER_GITEA_CLIENT_SECRET}
      - WOODPECKER_AGENT_SECRET=${WOODPECKER_AGENT_SECRET}
      - WOODPECKER_ADMIN=${WOODPECKER_ADMIN_USER}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8000/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.woodpecker.rule=Host(`${SUBDOMAIN_WOODPECKER}.${DOMAIN}`)"
      - "traefik.http.routers.woodpecker.tls=true"
      - "traefik.http.routers.woodpecker.tls.certresolver=cloudflare"
      - "traefik.http.services.woodpecker.loadbalancer.server.port=8000"
      # Woodpecker's login is handled via Gitea's OAuth, so we protect it with forward auth
      # to ensure only valid users can even see the login page.
      - "traefik.http.routers.woodpecker.middlewares=authentik@docker"

  woodpecker-agent:
    image: woodpeckerci/woodpecker-agent:${VERSION_WOODPECKER_AGENT}
    container_name: woodpecker-agent
    restart: unless-stopped
    networks:
      - shared-internal-net # Internal only
    depends_on:
      woodpecker-server:
        condition: service_healthy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WOODPECKER_SERVER=woodpecker-server:9000
      - WOODPECKER_AGENT_SECRET=${WOODPECKER_AGENT_SECRET}
      - WOODPECKER_MAX_WORKFLOWS=4
    deploy:
      resources:
        limits:
          # Tune based on expected build loads
          cpus: '2.0'
          memory: 4G

networks:
  traefik-public:
    external: true
  shared-internal-net:
    external: true
```

---

### **`collaboration/`**

#### **`collaboration/.env.example`**
```dotenv
# Location: /collaboration/.env.example

# --- GLOBAL SETTINGS ---
DOMAIN=your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata
POSTGRES_USER=postgres

# --- DOCKER IMAGE VERSIONS ---
VERSION_POSTGRES=16-alpine
VERSION_MATRIX_SYNAPSE=latest

# --- SUBDOMAINS ---
SUBDOMAIN_MATRIX=matrix

# --- DATABASE CREDENTIALS ---
MATRIX_DB_PASS=!!!_GENERATE_A_STRONG_AND_UNIQUE_PASSWORD_!!!

# --- MATRIX SECRETS ---
# This secret is used in homeserver.yaml to allow new user registrations via a shared secret.
MATRIX_REGISTRATION_SECRET=!!!_GENERATE_A_RANDOM_SECRET_!!!
```

#### **`collaboration/docker-compose.yml`**
```yaml
# Location: /collaboration/docker-compose.yml

version: '3.8'

services:
  database:
    image: postgres:${VERSION_POSTGRES}
    container_name: matrix-db
    restart: unless-stopped
    networks:
      - shared-internal-net
    volumes:
      - ${APPDATA_PATH}/collaboration/matrix-db:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${MATRIX_DB_PASS}
      - POSTGRES_DB=synapse
      # Required settings for Synapse database
      - POSTGRES_INITDB_ARGS=--encoding='UTF8' --lc-collate='C' --lc-ctype='C'
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d synapse -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  synapse:
    image: matrixdotorg/synapse:${VERSION_MATRIX_SYNAPSE}
    container_name: matrix-synapse
    restart: unless-stopped
    networks:
      - shared-internal-net
      - traefik-public
    volumes:
      - ${APPDATA_PATH}/collaboration/synapse_data:/data
    depends_on:
      database:
        condition: service_healthy
    # !!! CRITICAL INSTRUCTIONS !!!
    # 1. First time running, uncomment the 'command' line below to generate a homeserver.yaml.
    #    docker-compose up -d
    # 2. Stop the container immediately after it starts.
    #    docker-compose down
    # 3. Edit the generated /collaboration/synapse_data/homeserver.yaml.
    #    - Set up the database connection details.
    #    - Set 'enable_registration: true' and add the registration_shared_secret.
    #    - Configure federation and other critical settings.
    # 4. Comment out the 'command' line again.
    # 5. Start the stack normally.
    #    docker-compose up -d
    #
    # command: generate -H matrix.${DOMAIN} --report-stats=no

networks:
  traefik-public:
    external: true
  shared-internal-net:
    external: true
```

---

### **`operations/`**

#### **`operations/.env.example`**
```dotenv
# Location: /operations/.env.example

# --- GLOBAL SETTINGS ---
DOMAIN=your-domain.com
APPDATA_PATH=/mnt/your-pool/docker/appdata

# --- DOCKER IMAGE VERSIONS ---
VERSION_HOMEPAGE=latest
# Taiga uses rolling tags, defined in the compose file

# --- SUBDOMAINS ---
SUBDOMAIN_HOMEPAGE=dashboard
SUBDOMAIN_TAIGA=taiga
SUBDOMAIN_DOCS_INTERNAL=docs-internal
SUBDOMAIN_DOCS_EXTERNAL=docs

# --- TAIGA SECRETS (all should be unique and random) ---
# See the official taiga-docker repository for a full list of required variables.
# This is a subset of the most critical ones.
TAIGA_SECRET_KEY=!!!_GENERATE_A_RANDOM_SECRET_!!!
TAIGA_RABBITMQ_USER=taiga
TAIGA_RABBITMQ_PASSWORD=!!!_GENERATE_A_STRONG_PASSWORD_!!!
```

#### **`operations/docker-compose.yml`**
```yaml
# Location: /operations/docker-compose.yml

version: '3.8'

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:${VERSION_HOMEPAGE}
    container_name: homepage
    user: "1000:1000"
    restart: unless-stopped
    networks:
      - traefik-public
    volumes:
      # The config directory contains all widgets, settings, and bookmarks.
      - ${APPDATA_PATH}/operations/homepage_config:/app/config:rw
      # Read-only access to Docker socket for automatic service discovery.
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.homepage.rule=Host(`${SUBDOMAIN_HOMEPAGE}.${DOMAIN}`)"
      - "traefik.http.routers.homepage.tls=true"
      - "traefik.http.routers.homepage.tls.certresolver=cloudflare"
      - "traefik.http.services.homepage.loadbalancer.server.port=3000"
      - "traefik.http.routers.homepage.middlewares=authentik@docker"

  # --- Docusaurus Placeholder ---
  # Docusaurus requires a custom build process. This service assumes you have a
  # pre-built Docker image containing your static site, served by a webserver like Nginx.
  # A CI/CD pipeline in Woodpecker should be responsible for building and pushing this image.
  #
  # docusaurus-internal:
  #   image: your-registry/docusaurus-internal:latest
  #   container_name: docusaurus-internal
  #   restart: unless-stopped
  #   networks:
  #     - traefik-public
  #   labels:
  #     - "traefik.enable=true"
  #     - "traefik.http.routers.docusaurus-internal.rule=Host(`${SUBDOMAIN_DOCS_INTERNAL}.${DOMAIN}`)"
  #     - "traefik.http.routers.docusaurus-internal.tls=true"
  #     - "traefik.http.routers.docusaurus-internal.tls.certresolver=cloudflare"
  #     - "traefik.http.services.docusaurus-internal.loadbalancer.server.port=80"
  #     - "traefik.http.routers.docusaurus-internal.middlewares=authentik@docker"

  # --- Taiga Placeholder ---
  # The Taiga stack is complex (6+ containers). It is strongly recommended to
  # adapt the official taiga-docker repository's docker-compose.yml file.
  # You would integrate it here, ensuring:
  # 1. It uses an external postgres database (from the `dev` or a dedicated stack).
  # 2. It connects to the `shared-internal-net` and `traefik-public` networks.
  # 3. The `taiga-gateway` or `taiga-front` service has the appropriate Traefik labels.
  # 4. All secrets and hostnames are populated from your master .env file.

networks:
  traefik-public:
    external: true
```