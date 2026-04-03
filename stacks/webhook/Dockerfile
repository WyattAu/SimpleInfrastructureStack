FROM alpine:3.21

ARG SOPS_VERSION=3.12.2
ARG AGE_VERSION=1.2.0
ARG WEBHOOK_VERSION=2.8.0
ARG ANSIBLE_VERSION=2.20.4

# Install runtime dependencies
RUN apk add --no-cache \
    python3 \
    py3-pip \
    git \
    curl \
    openssh-client \
    su-exec

# Install Ansible
RUN pip3 install --break-system-packages ansible-core==${ANSIBLE_VERSION} && \
    ansible-galaxy collection install community.docker

# Install Docker CLI (compose v2 plugin included)
RUN apk add --no-cache docker-cli

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
    wget -qO /usr/local/bin/webhook \
        "https://github.com/adnanh/webhook/releases/download/v${WEBHOOK_VERSION}/webhook-linux-${ARCH}" && \
    chmod +x /usr/local/bin/webhook

# Create working directories
RUN mkdir -p /opt/webhook /root/.ssh

WORKDIR /opt/webhook

EXPOSE 9000

ENTRYPOINT ["webhook"]
CMD ["-hooks", "/opt/webhook/hooks.yaml", "-verbose", "-http-methods", "POST"]
