#!/usr/bin/env bash
set -euo pipefail

SERVICE="iris"
WEB_PORT=52773
NEW_PASSWORD="sys"  

# Cleanup function to run on script exit/failure
cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo ""
    echo "Script failed! Cleaning up..."
    docker compose down -v
  fi
}

# Set trap to run cleanup on script exit
trap cleanup EXIT

echo "▶  docker compose up -d"
docker compose up -d

# -----------------------------------------------------
# Wait for the IRIS container to start
# -----------------------------------------------------
echo "Waiting for IRIS to start "
max_attempts=60 
attempt=0

while [ "$attempt" -lt "$max_attempts" ]; do
  if docker compose ps -q "$SERVICE" >/dev/null 2>&1; then
    container_status=$(
      docker compose ps "$SERVICE" --format "table {{.State}}" \
        | tail -n +2 | tr -d '[:space:]'
    )
    if [ "$container_status" = "running" ]; then
      # Check if IRIS is really ready
      if docker compose exec -T "$SERVICE" \
           iris session IRIS -U %SYS </dev/null >/dev/null 2>&1 \
        || docker compose exec -T "$SERVICE" \
           curl -f -s --connect-timeout 3 http://localhost:52773/csp/sys/UtilHome.csp \
             >/dev/null 2>&1
      then
        break
      fi
    fi
  fi

  sleep 1
  attempt=$(( attempt + 1 ))
done

if [ $attempt -ge $max_attempts ]; then
  echo " Timeout"
  echo "IRIS did not start within the expected time. Check the logs with 'docker compose logs iris'."
  exit 1
fi

echo "Ready in $attempt seconds"

# -----------------------------------------------------
# Change the default password for the _SYSTEM user 
# to sys prevent manually changing it on first login.
# -----------------------------------------------------

COOKIE_JAR=$(mktemp)
URL="http://localhost:52773/csp/sys/UtilHome.csp"

# Helper function to extract the session token from the cookie jar
# Cookie format: Netscape cookie file 
# <domain>  <flag>  <path>  <secure>  <expiration>  <name>  <value>
# 7th field is the token
get_token() {
  grep IRISSessionToken "$COOKIE_JAR" | tail -1 | awk '{print $7}'
}

curl -s -c "$COOKIE_JAR" "$URL" >/dev/null

curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "IRISSessionToken=$(get_token)" \
  --data-urlencode "IRISUsername=_SYSTEM" \
  --data-urlencode "IRISPassword=SYS" \
  --data-urlencode "IRISLogin=Login" \
  "$URL" >/dev/null

curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "IRISSessionToken=$(get_token)" \
  --data-urlencode "IRISUsername=_SYSTEM" \
  --data-urlencode "IRISOldPassword=SYS" \
  --data-urlencode "IRISPassword=sys" \
  --data-urlencode "IRISLogin=Login" \
  "$URL" >/dev/null

echo "Attemping password change for _SYSTEM user to '$NEW_PASSWORD'"

# -----------------------------------------------------
# Check if the password change was successful
# -----------------------------------------------------
HTTP_CODE=$( \
  curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "IRISSessionToken=$(get_token)" \
    --data-urlencode "IRISUsername=_SYSTEM" \
    --data-urlencode "IRISPassword=sys" \
    --data-urlencode "IRISLogin=Login" \
    -w "%{http_code}" -o /dev/null \
    "$URL" \
)

rm "$COOKIE_JAR"

if [[ "$HTTP_CODE" == "302" ]]; then
  echo "HTTP login with new password succeeded. Use: _SYSTEM/$NEW_PASSWORD"
else
  echo "HTTP login failed (code $HTTP_CODE)"
  echo "Use default username/password: _SYSTEM/SYS"
fi

# -----------------------------------------------------
# Open the Management Portal in the default web browser
# -----------------------------------------------------
echo "Opening Management Portal..."
if command -v open >/dev/null 2>&1; then
  open "http://localhost:${WEB_PORT}/csp/sys/UtilHome.csp" # macOS
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://localhost:${WEB_PORT}/csp/sys/UtilHome.csp" # Linux
else
  echo "Please open: http://localhost:${WEB_PORT}/csp/sys/UtilHome.csp" # Fallback
fi