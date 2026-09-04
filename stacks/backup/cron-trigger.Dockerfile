FROM alpine:3.21

# Install docker CLI (needed to exec into backup-restic container)
# + bash: run-restore-test.sh / run-keycloak-export.sh require it
# (pipefail, date -Iseconds); without it the monthly restore test
# silently never ran (env: can't execute 'bash')
RUN apk add --no-cache docker-cli bash
