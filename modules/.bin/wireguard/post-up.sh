#!/usr/bin/bash
# /opt/wireguard-ui/postup.sh
ufw route allow in on wg0 out on eth0
iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE
