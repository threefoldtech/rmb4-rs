#!/usr/bin/env bash

case $1 in
  main|dev|qa|test )  # Ok
    ;;
  *)
  # The wrong first argument.
  echo 'Expected "dev", "qa", "test", or "main" as second arg' >&2
  exit 1
esac

if [ -z "$PRIVATE_KEY" ]; then
  echo 'PRIVATE_KEY is not set'
  echo 'Please set the PRIVATE_KEY environment variable'
  echo 'Example: PRIVATE_KEY="..." ./test_live_nodes.sh <NETWORK-ALIAS>'
  exit 1
fi

if [[ "$1" == 'main' ]]; then
  REGISTRAR_URL='https://registrar.prod4.grid.tf'
  RELAY_URL='wss://relay.grid.tf'
else
  REGISTRAR_URL="https://registrar.prod4.grid.tf"
  RELAY_URL="wss://relay.$1.grid.tf"
fi
RMB_LOG_FILE='./rmb-peer.log'
TIMEOUT="${TIMEOUT:-60}"
RMB_BIN="${RMB_BIN:-../../target/x86_64-unknown-linux-musl/release/rmb-peer}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

if [ -f "$RMB_BIN" ]; then
  binary_version_output=$( "$RMB_BIN" --version )
else
  echo "rmb-peer binary not found at $RMB_BIN"
  exit 1
fi

cleanup() {
  set +e
  debug 'cleaning up initiated'
  if [ -n "$VIRTUAL_ENV" ]; then
    debug 'deactivating virtual environment'
    deactivate
  fi
  # close redis-server
  debug 'closing redis-server ...'
  redis-cli -p 6379 shutdown
  jlist=$(jobs -pr)
  plist=$(ps --ppid $$ | awk '/[0-9]/{print $1}' | grep -v -E "^$$|^$(pgrep -f 'ps')|^$(pgrep -f 'awk')|^$(pgrep -f 'grep')$")
  pids=${jlist:-$plist}
  if [ -n "$pids" ]; then
    debug "stop rmb-peer and all bash managed jobs"
    kill $pids
  else
    debug "All jobs in this bash session have completed or stoped, so there are none left to clean up."
  fi
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "$@"
    fi
}

trap cleanup SIGHUP	SIGINT SIGQUIT SIGABRT SIGTERM

echo 'starting live nodes rmb test script ...'
echo "network: $1net"
debug "script version: $(git describe --tags)"
debug "rmb-peer version: $binary_version_output"
# start redis in backgroud and skip errors in case alreday running
set +e
debug 'redis-server starting ...'

redis-server --port 6379 > /dev/null 2>&1 &
sleep 3
# clear all databases
debug 'Removes all keys in Redis'
redis-cli -p 6379 FLUSHALL > /dev/null 2>&1 &
set -e

# ensure that RMB is not already running
if pgrep -x $(basename "$RMB_BIN") > /dev/null; then
    echo 'Another instance of rmb-peer is already running. Killing...'
    pkill -x $(basename "$RMB_BIN")
fi

# ensure the PRIVATE_KEY has no leading or trailing spaces
PRIVATE_KEY="${PRIVATE_KEY#"${PRIVATE_KEY%%[![:space:]]*}"}"; PRIVATE_KEY="${PRIVATE_KEY%"${PRIVATE_KEY##*[![:space:]]}"}"

# start rmb in background
debug "rmb-peer starting ($1net).."
$RMB_BIN --secret "$PRIVATE_KEY" --registrar "$REGISTRAR_URL" --relay "$RELAY_URL" --redis "redis://localhost:6379" --debug &> $RMB_LOG_FILE &

# wait till peer establish connection to a relay
if ! timeout --preserve-status 20 tail -f -n0 $RMB_LOG_FILE | grep -qe 'now connected'; then
    echo "rmb-peer taking too much time to start! check the log at $RMB_LOG_FILE for more info."
    cleanup
    exit 1
fi

# start rmb_tester
source venv/bin/activate
debug "rmb_tester starting .."
python3 ./rmb_tester.py -d $(./scripts/twins.sh --likely-up $1) -c "zos.system.version" -t "$TIMEOUT" -e "$TIMEOUT" $(if [[ "$VERBOSE" == "false" ]]; then echo "--short"; fi)

cleanup
