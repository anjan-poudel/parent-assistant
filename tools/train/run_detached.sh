#!/usr/bin/env bash
# Start/stop/restart run_stages.sh detached from the terminal (nohup +
# setsid) so a dropped SSH connection never kills training. stdout+stderr
# go to logs/run_stages_<timestamp>.log; the running pid+log are kept in
# logs/.run_stages.pid.
#
# Usage:
#   ./run_detached.sh            # start (same as: ./run_detached.sh start)
#   ./run_detached.sh status     # pid + log path
#   ./run_detached.sh stop       # stop the whole stage group (safe anytime)
#   ./run_detached.sh restart    # stop + start with a fresh log
set -euo pipefail
cd "$(dirname "$0")"

LOG_DIR="logs"
PID_FILE="$LOG_DIR/.run_stages.pid"

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cut -d' ' -f1 "$PID_FILE")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

print_status() {
    if is_running; then
        echo "running (pid $(cut -d' ' -f1 "$PID_FILE"))"
        echo "log: $(cut -d' ' -f2- "$PID_FILE")"
    elif [ -f "$PID_FILE" ]; then
        echo "not running (last log: $(cut -d' ' -f2- "$PID_FILE"))"
    else
        echo "not running"
    fi
}

stop() {
    if ! is_running; then
        print_status
        rm -f "$PID_FILE"
        return 0
    fi
    local pid log
    pid="$(cut -d' ' -f1 "$PID_FILE")"
    log="$(cut -d' ' -f2- "$PID_FILE")"
    echo "stopping pid $pid (see $log)"
    # setsid put the script in its own session/process group (pgid == pid);
    # kill the whole group so python children die with it.
    kill -- "-$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "still alive after 20s — SIGKILL"
        kill -9 -- "-$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "stopped"
}

start() {
    if is_running; then
        print_status
        echo "already running — './run_detached.sh restart' to restart"
        exit 1
    fi
    mkdir -p "$LOG_DIR"
    local ts log
    ts="$(date +%Y%m%d_%H%M%S)"
    log="$LOG_DIR/run_stages_${ts}.log"
    # nohup ignores SIGHUP from a dropped SSH connection; setsid detaches
    # from the terminal session entirely. </dev/null keeps it input-free.
    nohup setsid --wait ./run_stages.sh >"$log" 2>&1 </dev/null &
    local pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "failed to start — see $log"
        exit 1
    fi
    echo "$pid $log" > "$PID_FILE"
    echo "started (pid $pid)"
    echo "log: $log"
    echo "watch: tail -f $log"
}

case "${1:-start}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) print_status ;;
    *) echo "usage: $0 [start|stop|restart|status]" >&2; exit 2 ;;
esac
