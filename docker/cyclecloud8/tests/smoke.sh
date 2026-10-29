#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: bash $0 IMAGE [STARTUP_TIMEOUT_SECONDS (default: 900)]" >&2
    exit 2
fi

image=$1
startup_timeout=${2:-900}
if [[ ! $startup_timeout =~ ^[1-9][0-9]{0,4}$ ]]; then
    echo "Startup timeout must be a positive integer of at most five digits." >&2
    exit 2
fi

for tool in docker openssl; do
    if ! command -v "$tool" >/dev/null; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done
docker info >/dev/null
docker image inspect "$image" >/dev/null

container_id=
test_workdir=
cleanup() {
    result=$?
    trap - EXIT
    if [[ -n $container_id ]]; then
        if (( result != 0 )); then
            echo "FAIL: CycleCloud container smoke test; last 100 startup log lines:" >&2
            docker logs --tail 100 "$container_id" >&2 || true
        fi
        if ! docker rm --force --volumes "$container_id" >/dev/null; then
            echo "Failed to remove test container: $container_id" >&2
            exit 1
        fi
    fi
    if [[ -n $test_workdir ]]; then
        if ! docker run --rm --pull=never --network none --user 0:0 \
            --mount "type=bind,source=$test_workdir,target=/smoke" \
            --entrypoint /bin/bash "$image" \
            -c 'rm -rf -- /smoke/work /smoke/config /smoke/data'; then
            echo "Failed to clean test volume directories: $test_workdir" >&2
            result=1
        elif ! rmdir -- "$test_workdir"; then
            echo "Failed to remove test working directory: $test_workdir" >&2
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_empty_volumes() {
    local directory
    test_workdir=$(mktemp -d "$PWD/.cyclecloud-smoke.XXXXXX")
    for directory in work config data; do
        mkdir "$test_workdir/$directory"
    done
    # Match the writable volume ownership supplied by Kubernetes, without host sudo.
    docker run --rm --pull=never --network none --user 0:0 \
        --mount "type=bind,source=$test_workdir,target=/smoke" \
        --entrypoint /bin/bash "$image" \
        -c 'chown 1169:1169 /smoke/work /smoke/config /smoke/data'
    for directory in work config data; do
        if [[ -n $(find "$test_workdir/$directory" -mindepth 1 -print -quit) ]]; then
            echo "FAIL: volume directory is not empty: $test_workdir/$directory" >&2
            exit 1
        fi
    done
}

for test_case in image empty-volumes existing-volumes; do
    echo "----------------------------------------"
    echo "Test case: $test_case"
    echo "----------------------------------------"

    echo "Testing startup: $test_case"
    mount_args=()
    if [[ $test_case == empty-volumes ]]; then
        prepare_empty_volumes
    fi
    if [[ $test_case != image ]]; then
        mount_args+=(--read-only
            --tmpfs /tmp:rw,exec,nosuid,mode=1777
            --tmpfs /opt/cycle_server/logs:uid=1169,gid=1169,mode=0755
            --tmpfs /opt/cycle_server/.ssh:uid=1169,gid=1169,mode=0700
            --tmpfs /opt/cycle_server/system:rw,exec,uid=1169,gid=1169,mode=0755)
        for directory in work config data; do
            mount_args+=(--mount "type=bind,source=$test_workdir/$directory,target=/opt/cycle_server/$directory")
        done
    fi

    # Only disposable credentials are used: the startup script traces its arguments.
    test_password="Aa1!$(openssl rand -hex 24)"
    container_id=$(docker run --detach --pull=never --network none \
        "${mount_args[@]}" \
        --env "CYCLECLOUD_PASSWORD=$test_password" \
        --env CYCLECLOUD_USERNAME=smoke-admin \
        --env USE_WORKLOAD_IDENTITY=false \
        --env GENERATE_CS_CONFIG=true \
        --env ENTRA_ENABLED=false \
        --env ENTRA_USERNAME=smoke-admin \
        --env ENTRA_UID=19000 \
        --env DRYRUN=--dryrun \
        --env NO_DEFAULT_ACCOUNT=--noDefaultAccount \
        --env CYCLECLOUD_WEBSERVER_MAX_HEAP_SIZE=1024M \
        --env CYCLECLOUD_WEBSERVER_PORT=8080 \
        --env CYCLECLOUD_WEBSERVER_SSL_PORT=8443 \
        --env CYCLECLOUD_WEBSERVER_CLUSTER_PORT=9443 \
        --env CYCLECLOUD_HOSTNAME=localhost \
        --env CYCLECLOUD_FORCE_DELETE_VMS=false \
        --env CYCLECLOUD_FORCE_DELETE_VMSS=false \
        --entrypoint /bin/bash "$image" \
        -c 'touch /tmp/cyclecloud-smoke-started && exec /bin/bash /cs-install/scripts/run_cyclecloud.sh')
    unset test_password

    if [[ $test_case != image ]]; then
        if [[ $(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container_id") != true ]]; then
            echo "FAIL: volume test container must have a read-only root filesystem." >&2
            exit 1
        fi
        echo "PASS: volume test container has a read-only root filesystem."
    fi

    actual_user=$(docker exec "$container_id" id -un)
    actual_uid=$(docker exec "$container_id" id -u)
    actual_gid=$(docker exec "$container_id" id -g)
    if [[ $actual_user != cycle_server || $actual_uid != 1169 || $actual_gid != 1169 ]]; then
        echo "FAIL: expected cycle_server (1169:1169), got $actual_user ($actual_uid:$actual_gid)." >&2
        exit 1
    fi
    docker exec "$container_id" /bin/bash -c \
        'test "$(awk "/^Uid:/ {print \$2}" /proc/1/status)" = 1169'
    echo "PASS: default runtime user and startup process are non-root (cycle_server, UID 1169)."

    deadline=$((SECONDS + startup_timeout))
    healthy=false
    while (( SECONDS < deadline )); do
        if [[ $(docker inspect --format '{{.State.Running}}' "$container_id") != true ]]; then
            echo "FAIL: container exited before startup completed." >&2
            exit 1
        fi
        # Persisted CLI config must be refreshed by this container's startup.
        if docker exec "$container_id" /bin/bash -ec '
            config=/opt/cycle_server/work/cli-home/.cycle/config.ini
            test -s "$config"
            test "$config" -nt /tmp/cyclecloud-smoke-started
        '; then
            if http_code=$(docker exec "$container_id" curl --insecure --silent --show-error \
                --connect-timeout 2 --max-time 5 --output /dev/null \
                --write-out '%{http_code}' https://localhost:8443/health_monitor); then
                if [[ $http_code == 200 ]]; then
                    docker exec "$container_id" /opt/cycle_server/cycle_server status
                    echo "PASS: CLI initialized, CycleCloud is running, and HTTPS /health_monitor returns 200."
                    healthy=true
                    break
                fi
                echo "Waiting for health_monitor: HTTP $http_code." >&2
            fi
        fi
        sleep 2
    done

    if [[ $healthy != true ]]; then
        echo "FAIL: startup and service health did not pass within ${startup_timeout}s." >&2
        exit 1
    fi

    if [[ $test_case != image ]]; then
        docker exec "$container_id" /bin/bash -ec '
            for directory in work system config data; do
                test -w "/opt/cycle_server/$directory"
            done
            cmp /opt_cycle_server/system/version /opt/cycle_server/system/version
            test -s /opt/cycle_server/config/cycle_server.properties
            test -s /opt/cycle_server/data/ads/master.logfile
            test -d /opt/cycle_server/work/staging
        '
        echo "PASS: ephemeral system directory was populated from the container image."
        if [[ $test_case == empty-volumes ]]; then
            # Simulate an older persisted config: drop a file the image provides
            # and locally modify another that must not be overwritten.
            docker exec "$container_id" /bin/bash -ec '
                for directory in work config data; do
                    printf "%s\n" "$directory" > "/opt/cycle_server/$directory/.smoke-persistence"
                done
                rm -f /opt/cycle_server/config/init/README.txt
                printf "/* smoke-local-edit */\n" >> /opt/cycle_server/config/web/theme.css
            '
            echo "PASS: empty host-mounted work, config, and data directories were initialized."
        else
            docker exec "$container_id" /bin/bash -ec '
                for directory in work config data; do
                    test "$(cat "/opt/cycle_server/$directory/.smoke-persistence")" = "$directory"
                done
                cmp /opt_cycle_server/config/init/README.txt /opt/cycle_server/config/init/README.txt
                grep -qF "/* smoke-local-edit */" /opt/cycle_server/config/web/theme.css
            '
            echo "PASS: existing volumes retained markers; persisted config gained missing image files without overwriting local edits."
        fi
    fi

    docker exec "$container_id" /opt/cycle_server/cycle_server stop
    docker rm --force --volumes "$container_id" >/dev/null
    container_id=
done
