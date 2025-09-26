#!/bin/bash
printenv
# replace oCIS domain in keycloak realm import
mkdir /opt/keycloak/data/import
sed -e "s/ocis.owncloud.test/${OCIS_DOMAIN}/g" /opt/keycloak/data/import-dist/company-realm.json > /opt/keycloak/data/import/company-realm.json

# run original docker-entrypoint
/opt/keycloak/bin/kc.sh "$@"
