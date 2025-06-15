# Dynamically calculate endpoint IP and adjust routing
ENDPOINT_IP=$(wg show wg0 endpoints | awk '{print $2}' | cut -d':' -f1)
DEFAULT_ROUTE=$(ip route | grep default)
GW=$(echo $DEFAULT_ROUTE | cut -d ' ' -f3)
DEV=$(echo $DEFAULT_ROUTE | cut -d ' ' -f5)

if ip route | grep -q $ENDPOINT_IP; then
ip route delete $(ip route | grep $ENDPOINT_IP)
fi

ip route add $ENDPOINT_IP via $GW dev $DEV