HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | awk '{print $1}')
ANGIE_VERSION=$(angie -v 2>&1 | awk -F': ' '{print $2}')


echo "=== System Stats ==="
echo "Hostname: $HOSTNAME"
echo "IP Address: $IP_ADDRESS"
echo "Angie Version: $ANGIE_VERSION"
echo "===================="