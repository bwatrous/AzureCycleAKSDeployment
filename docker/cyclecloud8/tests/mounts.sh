#!/usr/bin/env bash
set -euo pipefail
trap 'echo "FAIL: mount regression at line $LINENO." >&2' ERR

if [[ ${1:-} != --container ]]; then
    if [[ $# != 1 ]]; then
        echo "Usage: bash $0 IMAGE" >&2
        exit 2
    fi
    tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    exec docker run --rm --pull=never --network none --read-only --user 0:0 \
        --tmpfs /tmp:mode=1777 \
        --tmpfs /opt/cycle_server:exec \
        --tmpfs /opt/cycle_server/data/ads:exec \
        --tmpfs /opt_cycle_server \
        --tmpfs /test-bin:exec \
        --mount "type=bind,source=$tests_dir/mounts.sh,target=/mounts.sh,readonly" \
        --mount "type=bind,source=$tests_dir/../scripts/run_cyclecloud.sh,target=/startup.sh,readonly" \
        --entrypoint /bin/bash "$1" /mounts.sh --container
fi

command -v setpriv >/dev/null
same_contents() {
    test "$(sha256sum < "$1")" = "$(sha256sum < "$2")"
}

mkdir -p /opt/cycle_server/{system,config,work,logs} \
    /opt_cycle_server/{system,config,work,data/ads}
cat > /test-bin/python3 <<'EOF'
#!/bin/bash
touch /tmp/installer-reached
exit 73
EOF
chmod 755 /test-bin/python3

run_startup() {
    local expected=${1:-73} result=0
    rm -f /tmp/installer-reached
    setpriv --reuid=1169 --regid=1169 --clear-groups \
        env PATH="/test-bin:$PATH" USE_WORKLOAD_IDENTITY=false \
        GENERATE_CS_CONFIG=false ENTRA_ENABLED=false \
        /bin/bash /startup.sh > /tmp/startup.log 2>&1 || result=$?
    if [[ $result != "$expected" ]]; then
        cat /tmp/startup.log >&2
        echo "FAIL: expected startup exit $expected, got $result." >&2
        exit 1
    fi
    if [[ ( $expected == 73 && ! -f /tmp/installer-reached ) ||
          ( $expected != 73 && -f /tmp/installer-reached ) ]]; then
        cat /tmp/startup.log >&2
        echo "FAIL: installer execution did not match the expected startup result." >&2
        exit 1
    fi
}

for ownership in 0:1169:2775 1169:1169:755; do
    IFS=: read -r uid gid mode <<< "$ownership"
    for directory in system config work data/ads; do
        root="/opt/cycle_server/$directory"
        find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        chown "$uid:$gid" "$root"
        chmod u-s,g-s "$root"
        chmod "$mode" "$root"
        source="/opt_cycle_server/$directory"
        mkdir -p "$source/nested"
        printf 'fixture\n' > "$source/.hidden"
        printf '#!/bin/bash\nexit 0\n' > "$source/nested/executable"
        chmod 755 "$source/nested/executable"
        printf 'spaces\n' > "$source/file with spaces"
        printf 'newline\n' > "$source/"$'file\nwith newline'
        ln -sfn nested/executable "$source/link"
    done
    mkdir -p /opt_cycle_server/config/data
    printf 'import\n' > /opt_cycle_server/config/data/consumed
    chown -R 1169:1169 /opt_cycle_server
    touch /opt/cycle_server/system/stale /opt/cycle_server/data/ads/stale
    run_startup
    for directory in system config work data/ads; do
        root="/opt/cycle_server/$directory"
        test "$(stat -c '%u:%g:%a' "$root")" = "$ownership"
        same_contents "/opt_cycle_server/$directory/.hidden" "$root/.hidden"
        test -x "$root/nested/executable"
        test "$(readlink "$root/link")" = nested/executable
        same_contents "/opt_cycle_server/$directory/file with spaces" "$root/file with spaces"
        same_contents "/opt_cycle_server/$directory/"$'file\nwith newline' "$root/"$'file\nwith newline'
    done
    test ! -e /opt/cycle_server/system/stale
    test ! -e /opt/cycle_server/data/ads/stale

    printf 'local edit\n' > /opt/cycle_server/config/.hidden
    rm /opt/cycle_server/config/data/consumed
    printf 'new default\n' > /opt_cycle_server/config/.new
    chown 1169:1169 /opt_cycle_server/config/.new
    touch /opt/cycle_server/system/stale
    run_startup
    test "$(cat /opt/cycle_server/config/.hidden)" = 'local edit'
    same_contents /opt_cycle_server/config/.new /opt/cycle_server/config/.new
    test ! -e /opt/cycle_server/config/data/consumed
    test ! -e /opt/cycle_server/system/stale
    for directory in system config work data/ads; do
        test "$(stat -c '%u:%g:%a' "/opt/cycle_server/$directory")" = "$ownership"
    done

    printf 'readable default\n' > /opt_cycle_server/config/readable
    printf 'unreadable default\n' > /opt_cycle_server/config/unreadable
    chmod 000 /opt_cycle_server/config/unreadable
    run_startup 2
    grep -qF 'Permission denied' /tmp/startup.log
    same_contents /opt_cycle_server/config/readable /opt/cycle_server/config/readable
    test ! -e /opt/cycle_server/config/unreadable
    chmod 644 /opt_cycle_server/config/unreadable
    run_startup
    same_contents /opt_cycle_server/config/unreadable /opt/cycle_server/config/unreadable
    test "$(cat /opt/cycle_server/config/.hidden)" = 'local edit'
    test ! -e /opt/cycle_server/config/data/consumed
    echo "PASS: archive producer failure stops startup; corrected retry succeeds ($ownership)."

    printf 'new default\n' > /opt_cycle_server/config/extraction-retry
    chmod 555 /opt/cycle_server/config
    run_startup 2
    grep -qF 'Permission denied' /tmp/startup.log
    test ! -e /opt/cycle_server/config/extraction-retry
    chmod "$mode" /opt/cycle_server/config
    run_startup
    same_contents /opt_cycle_server/config/extraction-retry /opt/cycle_server/config/extraction-retry
    test "$(stat -c '%u:%g:%a' /opt/cycle_server/config)" = "$ownership"
    test ! -e /opt/cycle_server/config/data/consumed
    echo "PASS: archive extraction failure stops startup; corrected retry succeeds ($ownership)."

    mkdir -p /opt/cycle_server/util
    cat > /opt/cycle_server/util/restore.sh <<'EOF'
#!/bin/bash
set -e
IFS= read -r answer
test "$answer" = yes
touch /tmp/restore-reached
EOF
    chmod 755 /opt/cycle_server/util/restore.sh
    touch /opt_cycle_server/data/ads/initial_load.marker
    rm -f /tmp/restore-reached
    run_startup
    grep -qF 'NUM_BACKUPS=0' /tmp/startup.log
    test ! -e /tmp/restore-reached
    test ! -e /opt/cycle_server/data/ads/initial_load.marker
    mkdir -p /opt/cycle_server/data/backups/{backup-001,backup-002}
    run_startup
    grep -qF 'NUM_BACKUPS=2' /tmp/startup.log
    test -f /tmp/restore-reached
    test ! -e /opt/cycle_server/data/ads/initial_load.marker
    rmdir /opt/cycle_server/data/backups/{backup-001,backup-002} /opt/cycle_server/data/backups
    echo "PASS: first-start backup counting and restore selection are unchanged ($ownership)."

    # Empty source directories must not turn an unmatched glob into a copy error.
    for directory in system config work data/ads; do
        find "/opt_cycle_server/$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        find "/opt/cycle_server/$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    done
    run_startup
    echo "PASS: initialization, restart, direct ads mount, and empty sources ($ownership)."
done
