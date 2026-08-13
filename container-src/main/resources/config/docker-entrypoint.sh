#!/bin/bash
set -euo pipefail

WILDFLY_HOME=/opt/jboss/wildfly

# If WILDFLY_USER and WILDFLY_PASS are set, add a management user (silent)
if [ -n "${WILDFLY_USER:-}" ] && [ -n "${WILDFLY_PASS:-}" ]; then
    echo "Adding management user: $WILDFLY_USER"
    ${WILDFLY_HOME}/bin/add-user.sh -s -u "$WILDFLY_USER" -p "$WILDFLY_PASS" -r ManagementRealm || true
    echo "Management user added successfully"
fi

# Start WildFly in the background
echo "Starting WildFly..."
"$@" &
WILDFLY_PID=$!

# Keep WildFly running in foreground
wait $WILDFLY_PID