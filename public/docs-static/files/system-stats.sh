get_server_status() {
    HOSTNAME=$(hostname)
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    ANGIE_VERSION=$(angie -v 2>&1 | awk -F': ' '{print $2}')
}