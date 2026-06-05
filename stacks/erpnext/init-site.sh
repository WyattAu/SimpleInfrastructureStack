#!/bin/bash
# Run once after containers are up to create ERPNext site
set -e

echo 'Waiting for backend...'
sleep 10

# Create new site
echo 'Creating site...'
docker exec erpnext-backend bench new-site erp.wyattau.com \
  --mariadb-root-password "$MYSQL_ROOT_PASSWORD" \
  --admin-password "$ERPNEXT_ADMIN_PASSWORD" \
  --db-host erpnext-mariadb || true

# Install ERPNext app
echo 'Installing erpnext app...'
docker exec erpnext-backend bench --site erp.wyattau.com install-app erpnext || true

# Set site as default
docker exec erpnext-backend bench use erp.wyattau.com || true

echo 'Site setup complete. Access at https://erp.wyattau.com'
echo 'Username: Administrator'
