#!/usr/bin/env bash

# VeeCode APIP (ADR-0008/ADR-0009): tests for the Lua docker-entrypoint,
# run against either published image variant. Uses the image in
# $KONG_DOCKER_TAG (falls back to the harness default kong-$BASE).
#
# Everything below the "image-variant assertions" chapter is contract-level
# and must pass against BOTH images. The variant-specific chapter asserts the
# shell-free property of the distroless image and, conversely, that the
# regular image still has a working shell.
#
# The variant is taken from $KONG_DISTROLESS (1/0); when unset it is derived
# from a `-distroless` suffix on the image tag.

function run_test {
  tinitialize "Docker-Kong test suite" "${BASH_SOURCE[0]}"

  local img="${KONG_DOCKER_TAG:-kong-$BASE}"
  local resty=/usr/local/openresty/bin/resty
  local distroless="${KONG_DISTROLESS:-}"
  if [ -z "$distroless" ]; then
    case "$img" in
      *-distroless) distroless=1 ;;
      *)            distroless=0 ;;
    esac
  fi

  tchapter "Image-variant assertions ($([ "$distroless" = 1 ] && echo distroless || echo regular))"

  if [ "$distroless" = 1 ]; then
    ttest "bash and /bin/sh are absent from the image"
    if docker run --rm --entrypoint /bin/bash "$img" -c true 2>/dev/null \
       || docker run --rm --entrypoint /bin/sh "$img" -c true 2>/dev/null; then
      tmessage "a shell is still present in the distroless image"
      tfailure
    else
      tsuccess
    fi

    # No rpm binary in this image, so probe the filesystem via resty instead
    # of asking the package database.
    ttest "no shell, package manager or build-helper binaries on disk"
    if docker run --rm --entrypoint "$resty" "$img" -e '
         for _, f in ipairs({ "/usr/bin/bash", "/bin/sh", "/usr/bin/rpm",
                              "/usr/bin/dnf", "/usr/bin/microdnf",
                              "/usr/bin/find", "/usr/sbin/useradd",
                              "/usr/bin/env" }) do
           local fd = io.open(f)
           if fd then fd:close() error(f .. " still present") end
         end
         print("absent")' | grep -q absent; then
      tsuccess
    else
      tmessage "a shell/package-manager/build-helper binary survived in the distroless image"
      tfailure
    fi
  else
    ttest "bash is present and usable in the regular image"
    if [ "$(docker run --rm --entrypoint /usr/bin/bash "$img" -c 'echo ok' 2>/dev/null)" = "ok" ]; then
      tsuccess
    else
      tmessage "bash is missing or not usable in the regular image"
      tfailure
    fi

    ttest "bash, findutils and shadow-utils RPMs are installed"
    if docker run --rm "$img" rpm -q bash findutils shadow-utils >/dev/null 2>&1; then
      tsuccess
    else
      tmessage "one of bash/findutils/shadow-utils is not installed"
      tfailure
    fi
  fi

  ttest "unzip is not installed"
  if docker run --rm --entrypoint "$resty" "$img" -e '
       local fd = io.open("/usr/bin/unzip")
       if fd then fd:close() error("unzip still present") end
       print("absent")' | grep -q absent; then
    tsuccess
  else
    tmessage "unzip is present in the image"
    tfailure
  fi

  tchapter "Lua entrypoint contract"

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
