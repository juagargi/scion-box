#!/bin/bash
# checks if this attachment point is ready. Sets it if not.
set -e


PORT=1194
NETWORK="10.0.8.0"
SUBNET="255.255.255.0"
SERVICE_NAME="server"
COORDINATOR_URL="https://www.scionlab.org"
no_vpn=0
inside_docker=0


CWD=$(pwd)
BASE=$(realpath $(dirname "$0"))
cd "$BASE"

usage="$(basename $0) -i IA [-a account_id] [-b account_secret] [-S server] [-p 1194] [-s 255.255.255.0] [-c 'https://www.scionlab.org']
where:
    -i IA           IA of this AS, also used to derive the name of the two VPN server files. E.g. 1-17, and will look for AS1-17.{crt,key}
    -a account_id   Account ID (per default cat $SC/gen/account_id)
    -b acc_secret   Account secret (per default cat $SC/gen/account_secret)
    -S service name (per default \"server\") You can specify a different VPN service name here (to use in e.g. systemctl status openvpn@server).
    -p Port         Port where the OpenVPN server will listen. Defaults to 1194.
    -n Net          Network for the OpenVPN server. Defaults to 10.0.8.0
    -s Subnet       Subnet to configure the OpenVPN server. Defaults to 255.255.255.0
    -c Coordinator  (per default https://www.scionlab.org) You can specify a different address for the Coordinator here.
    -t              Don't install any VPN files, only update scripts and services.
    -d              Run inside a docker container."
while getopts ":hi:p:n:s:a:b:tdS:c:" opt; do
case $opt in
    h)
        echo "$usage"
        exit 0
        ;;
    i)
        IA="$OPTARG"
        ASNAME="AS$IA"
        ;;
    p)
        PORT="$OPTARG"
        ;;
    n)
        NETWORK="$OPTARG"
        ;;
    s)
        SUBNET="$OPTARG"
        ;;
    a)
        ACC_ID="$OPTARG"
        ;;
    b)
        ACC_PWD="$OPTARG"
        ;;
    t)
        no_vpn=1
        ;;
    d)
        inside_docker=1
        ;;
    S)
        SERVICE_NAME="$OPTARG"
        ;;
    c)
        COORDINATOR_URL="$OPTARG"
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        echo "$usage" >&2
        exit 1
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        echo "$usage" >&2
        exit 1
        ;;
    esac
done

if [ $inside_docker -eq 1 ]; then
    no_vpn=1
fi

if [ -z "$ACC_ID" ] && [ -f "$SC/gen/account_id" ]; then
    ACC_ID=$(cat "$SC/gen/account_id")
fi
if [ -z "$ACC_PWD" ] && [ -f "$SC/gen/account_secret" ]; then
    ACC_PWD=$(cat "$SC/gen/account_secret")
fi

if [ "$no_vpn" -eq 0 ] && { [ -z "$ASNAME" ] || [ -z "$ACC_ID" ] || [ -z "$ACC_PWD" ]; } then
    echo "$usage"
    exit 1
fi

declare -a vpn_files=("$CWD/ca.crt"
                      "$CWD/dh4096.pem"
                      "$CWD/$ASNAME.crt"
                      "$CWD/$ASNAME.key")
declare -a updater_files=("$BASE/../update_gen.py"
                          "$BASE/../updateGen.sh"
                          "$BASE/../sub/util/local_config_util.py")
declare -a service_files=("$BASE/files/updateGen.service"
                          "$BASE/files/updateGen.timer")

declare -a files=("${updater_files[@]}")
if [ $inside_docker -eq 0 ]; then
    files+=("${service_files[@]}")
fi
if [ "$no_vpn" -eq 0 ]; then
    files+=("${vpn_files[@]}"
            "$BASE/files/server.conf")
fi

missingFiles=()
for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
        missingFiles+=("$f")
    fi
done

if [ ! -z "$missingFiles" ]; then
    echo "For this script to work we need the following files in the working directory:"
    echo "${files[@]}"
    echo "But there are missing files:"
    echo "${missingFiles[@]}"
    echo "Get the .key and .crt files from the Coordinator. Run ./build-key-server $ASNAME"
    exit 1
fi

# STEPS
pip3 install --user -r "../requirements.txt"
TMPFILE=$(mktemp)
if [ "$no_vpn" -eq 0 ]; then
    # (from https://help.ubuntu.com/lts/serverguide/openvpn.html)
    # install openvpn
    if ! dpkg-query -s openvpn &> /dev/null ; then
        sudo apt-get install openvpn -y
    fi

    # copy server conf to /etc/openvpn/server.conf
    cp "$BASE/files/server.conf" "$TMPFILE"
    sed -i -- "s/_PORT_/$PORT/g" "$TMPFILE"
    sed -i -- "s/_SRVNAME_/$SERVICE_NAME/g" "$TMPFILE"
    sed -i -- "s/_ASNAME_/$ASNAME/g" "$TMPFILE"
    sed -i -- "s/_NETWORK_/$NETWORK/g" "$TMPFILE"
    sed -i -- "s/_SUBNET_/$SUBNET/g" "$TMPFILE"
    sed -i -- "s/_USER_/$USER/g" "$TMPFILE"
    sudo mv "$TMPFILE" "/etc/openvpn/$SERVICE_NAME.conf"

    # copy the 4 files from coordinator
    sudo cp "${vpn_files[@]}" "/etc/openvpn/"
    sudo chmod 600 "/etc/openvpn/$ASNAME.key"

    # client configurations to get static IPs
    mkdir -p "$HOME/openvpn_ccd"

    # uncomment /etc/sysctl.conf ipv4.ip_foward and restart sysctl
    sudo sed -i -- 's/^#.*net.ipv4.ip_forward=1\(.*\)$/net.ipv4.ip_forward=1\1/g' "/etc/sysctl.conf"

    # start service systemctl start openvpn@server
    sudo systemctl stop "openvpn@$SERVICE_NAME" || true
    sudo systemctl start "openvpn@$SERVICE_NAME"
    sudo systemctl enable "openvpn@$SERVICE_NAME"

    # create the three ia, account_secret account_id files under gen :
    pushd "$SC/gen" >/dev/null
    [[ ! -f ia ]] && printf "$IA" > "ia"
    [[ ! -f account_id ]] && printf "$ACC_ID" > account_id
    [[ ! -f account_secret ]] && printf "$ACC_PWD" > account_secret
    popd >/dev/null
fi

# copy and run update gen
cp "${updater_files[@]}" "$HOME/.local/bin/"
sed -i -- "s|_COORDINATOR_URL_|$COORDINATOR_URL|g" "$HOME/.local/bin/updateGen.sh"
if [ $inside_docker -eq 0 ]; then
    echo "Stop and remove old service files (if they exist)"
    sudo systemctl stop "updateAS.timer" || true
    sudo systemctl stop "updateAS.service" || true
    sudo systemctl disable "updateAS.service" || true
    sudo rm -f "/etc/systemd/system/updateAS.timer"
    sudo rm -f "/etc/systemd/system/updateAS.service"
    sudo systemctl disable "updateAS.timer" || true
    echo "Stop service files"
    sudo systemctl stop "updateGen.timer" || true
    sudo systemctl stop "updateGen.service" || true
    for f in "${service_files[@]}"; do
        cp "$f" "$TMPFILE"
        sed -i "s|_USER_|$USER|g;s|/usr/local/go/bin|$(dirname $(which go))|g" "$TMPFILE"
        sudo cp "$TMPFILE" "/etc/systemd/system/$(basename $f)"
    done
    sudo systemctl daemon-reload
    echo "Enable service files"
    sudo systemctl enable "updateGen.service"
    sudo systemctl enable "updateGen.timer"
    echo "Start updater timer"
    sudo systemctl start "updateGen.timer"
fi

echo "Done."
