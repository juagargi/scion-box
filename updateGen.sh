#!/usr/bin/env bash

# This file is located in $SCIONBOX and called periodically by cron or systemd

set -e
SC="$HOME/go/src/github.com/scionproto/scion"
BASE=$(dirname $0)
if [ -f "$SC/gen/ia" ]; then
    IAS=$(cat $SC/gen/ia)
fi
if [ -f "$SC/gen/account_id" ]; then
    ACC_ID=$(cat $SC/gen/account_id)
fi
if [ -f "$SC/gen/account_secret" ]; then
    ACC_PW=$(cat $SC/gen/account_secret)
fi
if [ -f "$SC/gen/public_ip" ]; then
    IP_ADDR=$(cat $SC/gen/public_ip)
else
    IP_ADDR=$(hostname -I | awk '{print $1}')
fi
URL="https://www.scionlab.org"

# Parse named arguments string into array
args_string=$(echo " $*")
IFS=$'\n' ARGS=($(echo "$args_string" | awk '{split($0, out, " --"); for(e in out) {print out[e];}}'))
IFS=" "
for ARG in "${ARGS[@]}"
do
    # Split key=value
    KEY=$(echo $ARG | cut --fields=1 --only-delimited --delimiter=" ")
    VALUE=$(echo $ARG | cut --fields=2 --only-delimited --delimiter=" ")
    case "$KEY" in
        url)          URL=${VALUE} ;;
        updateAS)     IAS=($(echo ${VALUE}));; # IAS is an array
        accountId)    ACC_ID=${VALUE} ;;
        secret)       ACC_PW=${VALUE} ;;
        address)      IP_ADDR=${VALUE} ;;
        *)
    esac
done

export PYTHONPATH=$SC:$SC/python:$BASE/sub/util/:$BASE
for IA in "${IAS[@]}"; do
    echo "Updating AP for IA: $IA ..."
    python3 $BASE/update_gen.py --url "$URL" --updateAS "$IA" --accountId "$ACC_ID" --secret "$ACC_PW" --address "$IP_ADDR"
done
echo "Done updating AP."
