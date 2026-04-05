FROM alpine:3.21

# Install docker CLI (needed to exec into backup-restic container)
RUN apk add --no-cache docker-cli
