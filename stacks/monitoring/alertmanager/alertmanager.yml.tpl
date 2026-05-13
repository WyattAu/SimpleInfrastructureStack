---
# Alertmanager Configuration
# Docs: https://prometheus.io/docs/alerting/latest/configuration/

global:
  resolve_timeout: 5m

# Root route: all alerts enter here and are grouped by alertname.
# Child routes below match on severity to pick the right ntfy topic.
route:
  receiver: 'ntfy-info'
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Critical alerts → -critical topic
    - match:
        severity: critical
      receiver: 'ntfy'
      continue: false
    # Warning alerts → regular topic (also the default)
    - match:
        severity: warning
      receiver: 'ntfy-info'
      continue: false

receivers:
  - name: 'ntfy'
    webhook_configs:
      - url: '${NTFY_TOPIC_CRITICAL_URL}'
        send_resolved: true
  - name: 'ntfy-info'
    webhook_configs:
      - url: '${NTFY_TOPIC_INFO_URL}'
        send_resolved: true

inhibit_rules:
  # Don't warn about high memory if the container is already down
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: ['alertname', 'name']
