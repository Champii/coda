#!/bin/bash
export CODA_TIME_OFFSET=$(echo "$(date +%s) - $(date --date="2019-01-30 12:00:00-08:00" +%s)" | bc)
export CODA_PROPOSAL_INTERVAL=60

rm -r /tmp/conf*

mkdir /tmp/conf-8300
mkdir /tmp/conf-8400
mkdir /tmp/conf-8500

screen -d -m -S daemon1 ./src/_build/default/app/cli/src/coda.exe daemon -bind-ip 127.0.0.1 -client-port 8301 -external-port 8302 -rest-port 8310 -config-directory /tmp/conf-8300
screen -d -m -S daemon2 ./src/_build/default/app/cli/src/coda.exe daemon -bind-ip 127.0.0.1 -propose-key ./funded_wallet/key_new -peer 127.0.0.1:8303 -client-port 8401 -external-port 8402 -rest-port 8410 -config-directory /tmp/conf-8400
screen -d -m -S daemon3 ./src/_build/default/app/cli/src/coda.exe daemon -bind-ip 127.0.0.1 -run-snark-worker 8QnLVccgLBMXHM2BsYUjSwmX5cnjrGUxw2NZbA7CC98F6LGm2fKedzvRjusroWpySm -peer 127.0.0.1:8303 -client-port 8501 -external-port 8502 -rest-port 8510 -config-directory /tmp/conf-8500
#screen -d -m -S daemon3 ./src/_build/default/app/cli/src/coda.exe daemon -run-snark-worker ASimZyEdMGuyZwjhDnvtDGzy6zDXPCPR7ttnww/4lObSImEvjcJ8AgAAAA== -peer 127.0.0.1:8303 -ip 127.0.0.1 -client-port 8501 -external-port 8502 -rest-port 8510 -config-directory /tmp/conf-8500
