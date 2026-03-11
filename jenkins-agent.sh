#!/bin/bash

# Function to configure Java to use system certificates
configure_java_certificates() {
  # Update CA certificates if the directory is mounted from host
  if [ -d /etc/ssl/certs ] && [ -n "$(ls -A /etc/ssl/certs 2>/dev/null)" ]; then
    # Find Java home and cacerts location
    JAVA_BIN=$(which java 2>/dev/null || echo "/usr/bin/java")
    if [ -f "$JAVA_BIN" ]; then
      JAVA_HOME=$(dirname $(dirname $(readlink -f "$JAVA_BIN" 2>/dev/null || echo "$JAVA_BIN")))
      CACERTS="$JAVA_HOME/lib/security/cacerts"
      # Check if system-wide Java truststore exists (created by ca-certificates-java)
      if [ -f /etc/ssl/certs/java/cacerts ]; then
        # Use system-wide truststore
        export JAVA_OPTS="$JAVA_OPTS -Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts"
      elif [ -f "$CACERTS" ] && [ -w "$CACERTS" ] && command -v keytool >/dev/null 2>&1; then
        # Import individual certificates from /etc/ssl/certs if they exist
        # This handles custom/internal CA certificates mounted from the host
        cert_count=0
        for cert in /etc/ssl/certs/*.crt /etc/ssl/certs/*.pem; do
          if [ -f "$cert" ] && [ "$cert" != "/etc/ssl/certs/ca-certificates.crt" ]; then
            alias_name="host-cert-$(basename "$cert" | tr './' '_' | head -c 50)"
            keytool -importcert -noprompt -trustcacerts \
              -file "$cert" -alias "$alias_name" \
              -keystore "$CACERTS" -storepass changeit 2>/dev/null && cert_count=$((cert_count + 1)) || true
          fi
        done
        if [ $cert_count -gt 0 ]; then
          echo "Imported $cert_count certificate(s) into Java truststore"
        fi
      fi
    fi
  fi
}

# if `docker run` first argument start with `-` the user is passing jenkins swarm launcher arguments
if [[ $# -lt 1 ]] || [[ "$1" == "-"* ]]; then

  # Configure Java to use system certificates
  configure_java_certificates

  # jenkins swarm slave
  JAR=`ls -1 /usr/share/jenkins/swarm-client-*.jar | tail -n 1`

  # Convert -master to -url for swarm client 3.x compatibility and remove duplicates
  ARGS=("$@")
  JENKINS_URL_VALUE=""
  HAS_URL_PARAM=false

  # First pass: convert -master to -url
  for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "-master" ]]; then
      ARGS[$i]="-url"
    fi
  done

  # Remove duplicate -url parameters (keep only the first one)
  NEW_ARGS=()
  URL_SEEN=false
  i=0
  while [ $i -lt ${#ARGS[@]} ]; do
    if [[ "${ARGS[$i]}" == "-url" ]]; then
      if [ "$URL_SEEN" = false ]; then
        NEW_ARGS+=("${ARGS[$i]}")
        URL_SEEN=true
        HAS_URL_PARAM=true
        # Include the URL value
        if [ $((i+1)) -lt ${#ARGS[@]} ]; then
          JENKINS_URL_VALUE="${ARGS[$((i+1))]}"
          NEW_ARGS+=("${ARGS[$((i+1))]}")
          i=$((i+2))
          continue
        fi
      else
        # Skip duplicate -url and its value
        i=$((i+2))
        continue
      fi
    else
      NEW_ARGS+=("${ARGS[$i]}")
    fi
    i=$((i+1))
  done
  ARGS=("${NEW_ARGS[@]}")

  # If URL parameter is not provided, try to get it from environment variables
  if [ "$HAS_URL_PARAM" = false ]; then
    # Check for JENKINS_URL environment variable (preferred for swarm client 3.x)
    if [ ! -z "$JENKINS_URL" ]; then
      JENKINS_URL_VALUE="$JENKINS_URL"
      ARGS=("-url" "$JENKINS_URL" "${ARGS[@]}")
    # Check for JENKINS_MASTER_URL environment variable
    elif [ ! -z "$JENKINS_MASTER_URL" ]; then
      JENKINS_URL_VALUE="$JENKINS_MASTER_URL"
      ARGS=("-url" "$JENKINS_MASTER_URL" "${ARGS[@]}")
    # Legacy: Check for Docker link environment variable
    elif [ ! -z "$JENKINS_PORT_8080_TCP_ADDR" ]; then
      JENKINS_URL_VALUE="http://$JENKINS_PORT_8080_TCP_ADDR:${JENKINS_PORT_8080_TCP_PORT:-8080}"
      ARGS=("-url" "$JENKINS_URL_VALUE" "${ARGS[@]}")
    fi
  fi

  # Check if WebSocket mode should be enabled (useful when port 50000 is not accessible)
  # This allows connection through the Jenkins web interface instead of requiring direct JNLP port access
  HAS_WEBSOCKET_PARAM=false
  for arg in "${ARGS[@]}"; do
    if [[ "$arg" == "-webSocket" ]]; then
      HAS_WEBSOCKET_PARAM=true
      break
    fi
  done

  if [ "$HAS_WEBSOCKET_PARAM" = false ]; then
    # Check for SWARM_USE_WEBSOCKET environment variable
    if [ "${SWARM_USE_WEBSOCKET,,}" = "true" ] || [ "${SWARM_USE_WEBSOCKET}" = "1" ]; then
      ARGS=("-webSocket" "${ARGS[@]}")
      echo "WebSocket mode enabled (port 50000 not required)"
    # Auto-enable WebSocket for HTTPS URLs (port 50000 is often blocked in cloud/firewall scenarios)
    elif [[ "$JENKINS_URL_VALUE" =~ ^https:// ]]; then
      ARGS=("-webSocket" "${ARGS[@]}")
      echo "WebSocket mode auto-enabled for HTTPS (port 50000 not required)"
    fi
  fi

  echo Running java $JAVA_OPTS -jar $JAR -fsroot $HOME "${ARGS[@]}"
  exec java $JAVA_OPTS -jar $JAR -fsroot $HOME "${ARGS[@]}"
fi

# As argument is not jenkins, assume user want to run his own process, for sample a `bash` shell to explore this image
exec "$@"
