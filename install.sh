#!/bin/bash -xe

# Install swarm-client
groupadd -g ${gid} ${group}
useradd -d "${JENKINS_AGENT_HOME}" -u "${uid}" -g "${gid}" -m -s /bin/bash "${user}"
mkdir -p /usr/share/jenkins
wget -q -O /usr/share/jenkins/swarm-client-$JENKINS_SWARM_VERSION.jar $SWARM_PLUGIN_URL
chmod -R 755 /usr/share/jenkins

# Clean up any Debian repository references that might cause issues
if [ -f /etc/apt/sources.list ]; then
    sed -i '/debian.org/d' /etc/apt/sources.list
fi
if [ -d /etc/apt/sources.list.d ]; then
    find /etc/apt/sources.list.d -name "*.list" -exec sed -i '/debian.org/d' {} \;
fi

# Install few tools
apt-get update
apt-get -y install git git-lfs net-tools python2 python3 bzip2 lbzip2 netcat-openbsd rsync \
                 apt-transport-https ca-certificates curl software-properties-common wget unzip \
                 lsb-release gpg ca-certificates-java  \
                 iputils-ping iproute2 file psmisc
# Legacy (Debian) agent had bare `python` = 2.7; jammy has no python-is-python2
ln -sf /usr/bin/python2 /usr/bin/python

# jq v1.6 to support --rawfile
curl -fsSL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /usr/bin/jq
chmod +x /usr/bin/jq

# Install docker from official repos
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get -y install docker-ce

# Create symlinks to use lbzip2
cd /usr/local/bin
ln -s /usr/bin/lbzip2 bzip2
ln -s /usr/bin/lbzip2 bunzip2

# Provide docker group and make the executable accessible (ids from CoreOS & Debian)
groupadd -g 233 docker2
groupadd -g 998 docker3
usermod -a -G docker,docker2,docker3 "${user}"

# Set bash as default shell
echo "dash dash/sh boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash

# Add Tini
TINI_VERSION="v0.18.0"
mkdir -p "/opt/tini"
wget -q -O /opt/tini/tini https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static
chmod +x /opt/tini/tini

# Install encaps
cd /tmp
wget -q https://github.com/swi-infra/jenkins-docker-encaps/archive/master.zip
unzip master.zip
mv jenkins-docker-encaps-master/encaps* /usr/bin
rm -rf master.zip jenkins-docker-encaps-master

# Update Java truststore with system certificates
# This ensures Java can validate SSL certificates from the host system
update-ca-certificates -f || true

# For Java 9+, also ensure the system certificates are linked
if [ -d /etc/ssl/certs ] && [ -f /usr/lib/jvm/*/lib/security/cacerts ]; then
    # Find Java home
    JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java) 2>/dev/null || echo "/usr/bin/java"))) 2>/dev/null || JAVA_HOME="/usr/lib/jvm/default-java"
    if [ -f "$JAVA_HOME/lib/security/cacerts" ]; then
        # Link system certificates if not already linked
        if [ ! -L "$JAVA_HOME/lib/security/cacerts" ] && [ -f /etc/ssl/certs/java/cacerts ]; then
            # Use the system-wide cacerts if available
            ln -sf /etc/ssl/certs/java/cacerts "$JAVA_HOME/lib/security/cacerts" 2>/dev/null || true
        fi
    fi
fi

chown -R ${uid}:${gid} ${JENKINS_AGENT_HOME}

# Install clean-up
rm -rf /var/lib/apt/lists/*
