-- docker-entrypoint.lua
--
-- Lua port of docker-entrypoint.sh (this repository), so the runtime image
-- needs no shell. Runs under the native `resty` launcher (rusty-cli); uses
-- LuaJIT FFI for environment mutation and process control so the mutated
-- environment crosses the exec boundary. Linux-only by design (container
-- entrypoint).
--
-- Copyright 2016-2026 Kong Inc. and VeeCode
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local ffi = require "ffi"
local bit = require "bit"
local C = ffi.C

ffi.cdef [[
  typedef int32_t de_pid_t;

  de_pid_t fork(void);
  int execv(const char *path, char *const argv[]);
  int execvp(const char *file, char *const argv[]);
  de_pid_t waitpid(de_pid_t pid, int *status, int options);
  void _exit(int status);

  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);

  int symlink(const char *target, const char *linkpath);
  int unlink(const char *path);

  int sigemptyset(void *set);
  int sigaddset(void *set, int sig);
  int sigprocmask(int how, const void *set, void *oldset);

  char *strerror(int errnum);
]]

-- Linux constants (this entrypoint only ever runs inside the container)
local SIGCHLD     = 17
local SIG_BLOCK   = 0
local SIG_SETMASK = 2
local EINTR       = 4

local KONG_DEFAULTS_PATH =
  "/usr/local/share/lua/5.1/kong/templates/kong_defaults.lua"
local NGINX_BIN = "/usr/local/openresty/nginx/sbin/nginx"


local function stderr(msg)
  io.stderr:write(msg)
end

local function errno_string()
  return ffi.string(C.strerror(ffi.errno()))
end

local function build_cargv(argv)
  local n = #argv
  local cargv = ffi.new("const char *[?]", n + 1)
  for i = 1, n do
    cargv[i - 1] = argv[i]
  end
  cargv[n] = nil
  return ffi.cast("char *const *", cargv)
end

-- fork + execvp + waitpid, no shell. SIGCHLD is blocked around the wait
-- (like system(3)) because the temporary nginx hosting this script installs
-- a reaping SIGCHLD handler that would otherwise steal the exit status; the
-- child restores the original mask before exec.
local function spawn_wait(argv)
  local newset = ffi.new("long[16]")
  local oldset = ffi.new("long[16]")
  C.sigemptyset(newset)
  C.sigaddset(newset, SIGCHLD)
  C.sigprocmask(SIG_BLOCK, newset, oldset)

  local cargv = build_cargv(argv)
  local pid = C.fork()

  if pid == 0 then -- child
    C.sigprocmask(SIG_SETMASK, oldset, nil)
    C.execvp(argv[1], cargv)
    stderr("error: could not execute '" .. argv[1] .. "': "
           .. errno_string() .. "\n")
    C._exit(127)
  end

  if pid < 0 then
    C.sigprocmask(SIG_SETMASK, oldset, nil)
    stderr("error: fork() failed: " .. errno_string() .. "\n")
    os.exit(1)
  end

  local status = ffi.new("int[1]")
  local ret
  repeat
    ret = C.waitpid(pid, status, 0)
  until ret ~= -1 or ffi.errno() ~= EINTR

  C.sigprocmask(SIG_SETMASK, oldset, nil)

  if ret == -1 then
    stderr("error: waitpid() failed: " .. errno_string() .. "\n")
    os.exit(1)
  end

  local st = status[0]
  if bit.band(st, 0x7f) == 0 then
    -- WIFEXITED -> WEXITSTATUS
    return bit.band(bit.rshift(st, 8), 0xff)
  end
  -- WIFSIGNALED -> 128 + WTERMSIG (shell convention)
  return 128 + bit.band(st, 0x7f)
end

-- usage: file_env("XYZ_DB_PASSWORD")
-- allows "$XYZ_DB_PASSWORD_FILE" to fill in the value of "$XYZ_DB_PASSWORD"
-- from a file, especially for Docker's secrets feature
local function file_env(var)
  local file_var = var .. "_FILE"
  local file_val = os.getenv(file_var)

  -- do not continue if the _FILE env is not set
  if file_val == nil or file_val == "" then
    return
  end

  local val = os.getenv(var)
  if val ~= nil and val ~= "" then
    stderr("error: both " .. var .. " and " .. file_var
           .. " are set (but are exclusive)\n")
    os.exit(1)
  end

  local f, err = io.open(file_val, "r")
  if not f then
    stderr("error: could not read " .. file_var .. ": "
           .. tostring(err) .. "\n")
    os.exit(1)
  end

  local content = f:read("*a") or ""
  f:close()

  -- $(< file) strips trailing newlines
  content = content:gsub("\n+$", "")

  -- C setenv/unsetenv so the exec'd process inherits the mutation
  C.setenv(var, content, 1)
  C.unsetenv(file_var)
end

local function force_symlink(target, linkpath)
  C.unlink(linkpath) -- ENOENT is fine
  if C.symlink(target, linkpath) ~= 0 then
    stderr("error: could not symlink " .. linkpath .. " -> " .. target
           .. ": " .. errno_string() .. "\n")
    os.exit(1)
  end
end

-- remove all dangling unix sockets under `prefix` (and `prefix`/sockets),
-- warning once, before starting Kong
local function sweep_dangling_sockets(prefix)
  -- presence-marking the key first stops resty's _G write guard from
  -- warning when the lfs C module registers its global on load
  rawset(_G, "lfs", false)
  local lfs = require "lfs"

  local logged_warning = false

  for _, dir in ipairs({ prefix, prefix .. "/sockets" }) do
    local ok, iter, state = pcall(lfs.dir, dir)
    if ok then
      for name in iter, state do
        -- the shell version globbed `dir/*`: skip dotfiles too
        if name:sub(1, 1) ~= "." then
          local path = dir .. "/" .. name
          if lfs.attributes(path, "mode") == "socket" then
            if not logged_warning then
              stderr("WARN: found dangling unix sockets in the prefix "
                     .. "directory (" .. prefix .. ") while preparing "
                     .. "to start Kong. This may be a sign that Kong "
                     .. "was previously shut down uncleanly or is in an "
                     .. "unknown state and could require further "
                     .. "investigation.\n")
              logged_warning = true
            end
            os.remove(path)
          end
        end
      end
    end
  end
end


----------------------------------------------------------------------------
-- main
----------------------------------------------------------------------------

local daemon = os.getenv("KONG_NGINX_DAEMON")
if daemon == nil or daemon == "" then
  C.setenv("KONG_NGINX_DAEMON", "off", 1)
end

if arg[1] == "kong" then
  -- apply *_FILE secret expansion for every option in kong_defaults.lua
  local f = io.open(KONG_DEFAULTS_PATH, "r")
  if f then
    for line in f:lines() do
      local opt = line:match("^([%a_][%w_]*)%s*=")
      if opt then
        file_env("KONG_" .. opt:upper())
      end
    end
    f:close()
  end

  file_env("KONG_PASSWORD")

  local prefix = os.getenv("KONG_PREFIX")
  if prefix == nil or prefix == "" then
    prefix = "/usr/local/kong"
  end

  if arg[2] == "docker-start" then
    -- kong prepare -p $PREFIX "$@"
    local prepare_argv = { "kong", "prepare", "-p", prefix }
    for i = 1, #arg do
      prepare_argv[#prepare_argv + 1] = arg[i]
    end

    local code = spawn_wait(prepare_argv)
    if code ~= 0 then
      os.exit(code)
    end

    sweep_dangling_sockets(prefix)

    force_symlink("/dev/stdout", prefix .. "/logs/access.log")
    force_symlink("/dev/stdout", prefix .. "/logs/admin_access.log")
    force_symlink("/dev/stderr", prefix .. "/logs/error.log")

    -- exec nginx; on success this never returns and nginx (child of the
    -- rusty-cli PID 1, which forwards signals and propagates the exit
    -- status) serves until shutdown
    local nginx_argv = { NGINX_BIN, "-p", prefix, "-c", "nginx.conf" }
    C.execv(NGINX_BIN, build_cargv(nginx_argv))
    stderr("error: could not exec " .. NGINX_BIN .. ": "
           .. errno_string() .. "\n")
    os.exit(1)
  end
end

-- exec "$@"
if arg[1] == nil then
  os.exit(0)
end

local passthrough = {}
for i = 1, #arg do
  passthrough[#passthrough + 1] = arg[i]
end

C.execvp(passthrough[1], build_cargv(passthrough))
stderr("error: could not execute '" .. passthrough[1] .. "': "
       .. errno_string() .. "\n")
os.exit(127)
