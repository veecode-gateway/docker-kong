#!/usr/bin/env bash

# VeeCode APIP (ADR-0008): tests for the Lua docker-entrypoint and the
# shell-free runtime image. Uses the image in $KONG_DOCKER_TAG (falls back
# to the harness default kong-$BASE).

function run_test {
  tinitialize "Docker-Kong test suite" "${BASH_SOURCE[0]}"

  tchapter "Lua entrypoint / shell-free image"

  local img="${KONG_DOCKER_TAG:-kong-$BASE}"
  local resty=/usr/local/openresty/bin/resty

  ttest "bash and /bin/sh are absent from the image"
  if docker run --rm --entrypoint /bin/bash "$img" -c true 2>/dev/null \
     || docker run --rm --entrypoint /bin/sh "$img" -c true 2>/dev/null; then
    tmessage "a shell is still present in the image"
    tfailure
  else
    tsuccess
  fi

  ttest "bash, findutils, shadow-utils and unzip RPMs are not installed"
  if docker run --rm "$img" rpm -q bash findutils shadow-utils unzip 2>/dev/null \
       | grep -v 'not installed' | grep -q '^'; then
    tmessage "one of the build-only packages is still installed"
    tfailure
  else
    tsuccess
  fi

  ttest "inert OpenResty Perl scripts are pruned from openresty/bin"
  if docker run --rm --entrypoint "$resty" "$img" -e '
       for _, f in ipairs({ "md2pod.pl", "nginx-xml2pod", "opm",
                            "restydoc", "restydoc-index" }) do
         local fd = io.open("/usr/local/openresty/bin/" .. f)
         if fd then fd:close() error(f .. " still present") end
       end
       print("pruned")' | grep -q pruned; then
    tsuccess
  else
    tmessage "Perl scripts still present in /usr/local/openresty/bin"
    tfailure
  fi

  ttest "entrypoint passthrough exec works (kong version)"
  if docker run --rm "$img" kong version >/dev/null; then
    tsuccess
  else
    tmessage "passthrough exec of kong version failed"
    tfailure
  fi

  ttest "*_FILE secret is expanded and the _FILE var is unset across exec"
  # /proc/<nginx>/environ is useless here: nginx's setproctitle clobbers the
  # original environ region for every entrypoint (bash included). Instead,
  # prove the mutation crossed the exec boundary by asking an exec'd kong CLI
  # (the env vault reads the process environment of the exec'd child).
  local vol="kong_entrypoint_secret_$$"
  docker volume create "$vol" >/dev/null
  # seed as root: a fresh named volume is root-owned and the image runs as kong
  docker run --rm -u root -v "$vol:/secrets" --entrypoint "$resty" "$img" \
    -e 'local f = assert(io.open("/secrets/pgpass", "w"))
        f:write("s3cr3t-from-file\n") f:close()
        local ffi = require "ffi"
        ffi.cdef[[int chmod(const char *path, unsigned int mode);]]
        assert(ffi.C.chmod("/secrets/pgpass", 420) == 0) -- 0644' >/dev/null
  local expanded unset_rc
  expanded=$(docker run --rm -v "$vol:/secrets" \
               -e KONG_DATABASE=off \
               -e KONG_PG_PASSWORD_FILE=/secrets/pgpass \
               "$img" kong vault get env/kong_pg_password 2>/dev/null | tail -1)
  docker run --rm -v "$vol:/secrets" \
    -e KONG_DATABASE=off \
    -e KONG_PG_PASSWORD_FILE=/secrets/pgpass \
    "$img" kong vault get env/kong_pg_password_file >/dev/null 2>&1
  unset_rc=$?
  docker volume rm "$vol" >/dev/null
  if [ "$expanded" = "s3cr3t-from-file" ] && [ $unset_rc -ne 0 ]; then
    tsuccess
  else
    tmessage "expanded='$expanded' (want s3cr3t-from-file), _FILE lookup rc=$unset_rc (want != 0)"
    tfailure
  fi

  ttest "setting both VAR and VAR_FILE errors and exits 1"
  docker run --rm -e KONG_DATABASE=off \
    -e KONG_PG_PASSWORD=direct \
    -e KONG_PG_PASSWORD_FILE=/tmp/nope \
    "$img" kong docker-start >/tmp/both_set_out 2>&1
  local rc=$?
  if [ $rc -eq 1 ] && grep -q "are set (but are exclusive)" /tmp/both_set_out; then
    tsuccess
  else
    tmessage "expected exit 1 + exclusivity error, got rc=$rc: $(cat /tmp/both_set_out)"
    tfailure
  fi

  ttest "dangling socket sweep warns once and boot proceeds"
  local svol="kong_entrypoint_sweep_$$"
  docker volume create "$svol" >/dev/null
  docker run --rm -v "$svol:/usr/local/kong" --entrypoint "$resty" "$img" -e '
    local ffi = require "ffi"
    ffi.cdef[[
      int socket(int domain, int type, int protocol);
      struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
      int bind(int fd, const struct sockaddr_un *addr, unsigned int len);
    ]]
    local fd = ffi.C.socket(1, 1, 0) -- AF_UNIX, SOCK_STREAM
    assert(fd >= 0)
    local sa = ffi.new("struct sockaddr_un")
    sa.sun_family = 1
    ffi.copy(sa.sun_path, "/usr/local/kong/dangling.sock")
    assert(ffi.C.bind(fd, sa, ffi.sizeof(sa)) == 0, "bind failed")
    print("seeded")' | grep -q seeded || { tmessage "could not seed socket"; tfailure; }
  local sc
  sc=$(docker run -d -v "$svol:/usr/local/kong" -e KONG_DATABASE=off "$img")
  sleep 8
  local logs sweep_ok=1
  logs=$(docker logs "$sc" 2>&1)
  echo "$logs" | grep -q "WARN: found dangling unix sockets" || sweep_ok=0
  docker exec "$sc" "$resty" -e \
    'print(io.open("/usr/local/kong/dangling.sock") and "STILL_THERE" or "REMOVED")' \
    | grep -q REMOVED || sweep_ok=0
  docker rm -f "$sc" >/dev/null
  docker volume rm "$svol" >/dev/null
  if [ $sweep_ok -eq 1 ]; then
    tsuccess
  else
    tmessage "socket sweep did not warn or did not remove the socket"
    tfailure
  fi

  ttest "clean docker-start: healthy, proxy answers, logs on stdout/stderr"
  local bc
  bc=$(docker run -d -e KONG_DATABASE=off -p 18100:8000 "$img")
  local healthy=0
  for _ in $(seq 1 40); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$bc")" = "healthy" ]; then
      healthy=1; break
    fi
    sleep 3
  done
  local proxy_ok=0
  curl -si http://localhost:18100/ | grep -qi '^Server: kong/' && proxy_ok=1
  local links_ok=0
  docker exec "$bc" "$resty" -e '
    local ffi = require "ffi"
    ffi.cdef[[ long readlink(const char *path, char *buf, unsigned long size); ]]
    local buf = ffi.new("char[256]")
    local n = ffi.C.readlink("/usr/local/kong/logs/error.log", buf, 256)
    print(n > 0 and ffi.string(buf, n) or "NOTLINK")' | grep -q "/dev/stderr" && links_ok=1
  local stop_rc
  docker stop -t 30 "$bc" >/dev/null
  stop_rc=$(docker inspect -f '{{.State.ExitCode}}' "$bc")
  docker rm -f "$bc" >/dev/null
  if [ $healthy -eq 1 ] && [ $proxy_ok -eq 1 ] && [ $links_ok -eq 1 ] && [ "$stop_rc" = "0" ]; then
    tsuccess
  else
    tmessage "healthy=$healthy proxy=$proxy_ok links=$links_ok stop_exit=$stop_rc"
    tfailure
  fi

  tfinish
}

# No need to modify anything below this comment

# shellcheck disable=SC1090  # do not follow source
[[ "$T_PROJECT_NAME" == "" ]] && set -e && if [[ -f "${1:-$(dirname "$(realpath "$0")")/test.sh}" ]]; then source "${1:-$(dirname "$(realpath "$0")")/test.sh}"; else source "${1:-$(dirname "$(realpath "$0")")/run.sh}"; fi && set +e
run_test
