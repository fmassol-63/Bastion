# ~/Bastion/BASTION1/keepalived/entrypoint.sh
#!/bin/sh
set -e
echo "Generating keepalived.conf..."
sed "s/__VRRP_AUTH_PASS__/${VRRP_AUTH_PASS}/g" /tmp/keepalived.conf.template > /etc/keepalived/keepalived.conf
echo "Config generated, content:"
cat /etc/keepalived/keepalived.conf
echo "Starting keepalived..."
exec /usr/local/sbin/keepalived --dont-fork --log-console --log-detail -f /etc/keepalived/keepalived.conf
