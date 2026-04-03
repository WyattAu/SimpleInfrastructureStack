FROM alpine:3.21

ARG SOPS_VERSION=3.12.2
ARG AGE_VERSION=1.2.0
ARG WEBHOOK_VERSION=2.8.3
ARG ANSIBLE_VERSION=2.20.4
ARG COMPOSE_VERSION=v2.32.3

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    python3 \
    py3-pip \
    git \
    curl \
    openssh-client \
    su-exec \
    gettext

# Install Ansible
RUN pip3 install --break-system-packages ansible-core==${ANSIBLE_VERSION} && \
    ansible-galaxy collection install community.docker

# Install Docker CLI + Compose plugin (pinned to v2.32.3 for stability;
# v5.x has a bug parsing IPv6 address pools with CIDR notation)
RUN apk add --no-cache docker-cli && \
    mkdir -p /usr/local/lib/docker/cli-plugins && \
    wget -qO /usr/local/lib/docker/cli-plugins/docker-compose \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Install SOPS, age, and webhook binary (single layer to share ARCH)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) ARCH="amd64" ;; aarch64) ARCH="arm64" ;; *) echo "Unsupported: $ARCH" && exit 1 ;; esac && \
    wget -qO /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}" && \
    chmod +x /usr/local/bin/sops && \
    wget -qO /tmp/age.tar.gz \
        "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH}.tar.gz" && \
    tar xzf /tmp/age.tar.gz -C /usr/local/bin age && \
    rm /tmp/age.tar.gz && \
    wget -qO /tmp/webhook.tar.gz \
        "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-${ARCH}.tar.gz" && \
    tar xzf /tmp/webhook.tar.gz -C /usr/local/bin --strip-components=1 && \
    rm /tmp/webhook.tar.gz

# Create working directories
RUN mkdir -p /opt/webhook /root/.ssh

WORKDIR /opt/webhook

COPY entrypoint.sh /opt/webhook/entrypoint.sh

EXPOSE 9000

ENTRYPOINT ["/opt/webhook/entrypoint.sh"]
CMD ["-hooks", "/opt/webhook/hooks.yaml", "-verbose", "-http-methods", "POST"]
