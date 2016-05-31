local Arguments = require "argparse"
local Colors    = require "ansicolors"
local Et        = require "etlua"
local Redis     = require "redis"
local Jwt       = require "jwt"
local Copas     = require "copas.ev"
Copas:make_default ()
local Websocket = require "websocket"
local Time      = require "socket".gettime
local Util      = require "lapis.util"
local Config    = require "lapis.config".get ()
local Ltn12     = require "ltn12"
local Http      = require "socket.http"

local parser = Arguments () {
  name        = "cosy-editor",
  description = "collaborative editor for cosy models",
}
parser:option "--port" {
  description = "port",
  default     = "0",
  convert     = tonumber,
}
parser:argument "token" {
  description = "resource token",
}

local arguments = parser:parse ()

local data, err = Jwt.decode (arguments.token)
if not data then
  print (Colors (Et.render ("Failed to parse token: %{red}<%= error %>%{reset}", {
    error = err,
  })))
  os.exit (1)
end

local redis
do
  local ok, res = pcall (Redis.connect, Config.redis.host, Config.redis.port)
  if not ok then
    print (Colors (Et.render ("Runner failed to connect to redis instance %{green}<%= host %>%{reset}:%{green}<%= port %>%{reset}: %{red}<%= error %>%{reset}", {
      host     = Config.redis.host,
      port     = Config.redis.port,
      database = Config.redis.database,
      error    = res,
    })))
    os.exit (1)
  end
  redis = res
  ok, res = pcall (res.select, res, Config.redis.database)
  if not ok then
    print (Colors (Et.render ("Runner failed to switch to redis database %{green}<%= database %>%{reset}: %{red}<%= error %>%{reset}", {
      host     = Config.redis.host,
      port     = Config.redis.port,
      database = Config.redis.database,
      error    = res,
    })))
    os.exit (1)
  end
end
print (Colors (Et.render ("Runner listening on redis instance %{green}<%= host %>%{reset}:%{green}<%= port %>%{reset} database %{green}<%= database %>%{reset}.", {
  host     = Config.redis.host,
  port     = Config.redis.port,
  database = Config.redis.database,
})))

function _G.string.split (s, delimiter)
  local result = {}
  for part in s:gmatch ("[^" .. delimiter .. "]+") do
    result [#result+1] = part
  end
  return result
end

local function request (url, options)
  local result = {}
  local _, status = Http.request {
    url      = url,
    sink     = Ltn12.sink.table (result),
    method   = options.method,
    headers  = options.headers,
  }
  if status ~= 200 then
    return nil, status
  end
  return Util.from_json (table.concat (result)), status
end

local last_access = Time ()
local socket

Copas.addthread (function ()
  while true do
    Copas.sleep (Config.editor.timeout)
    if last_access + Config.editor.timeout <= Time () then
      -- FIXME: save model
      local _ = false
    end
    if last_access + Config.editor.timeout <= Time () then
      redis:del ("resource:" .. arguments.resource)
      Copas.removeserver (socket)
      return
    end
  end
end)

local model = request (Et.render (data.api .. "/projects/<%= project %>/resources/<%= resource %>", data), {
  method = "GET",
  headers = { Authorization = "Bearer " .. data.token},
})
if not model then
  redis:del     (data.key)
  redis:publish (data.key, Util.to_json {
    status = "finished",
  })
  return
end

local addserver = Copas.addserver
Copas.addserver = function (s, f)
  socket = s
  local host, port = s:getsockname ()
  addserver (s, f)
  local url = "ws://" .. host .. ":" .. tostring (port)
  redis:set (data.key, Util.to_json {
    status = "started",
    url    = url,
  })
  redis:publish (data.key, Util.to_json {
    status = "started",
    url    = url,
  })
  print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Start editor for %{green}<%= project %>/<%= resource %>%{reset} at %{green}<%= url %>%{reset}.", {
    project  = data.project,
    resource = data.resource,
    time     = os.date "%c",
    url      = url,
  })))
end

Websocket.server.copas.listen
{
  port      = arguments.port,
  protocols = {
    cosy = function (ws)
      last_access = Time ()
      local message   = ws:receive ()
      local greetings = message and Util.from_json (message)
      if not greetings then
        return
      end
      local token = greetings.token
      token = Jwt.decode (token, {
        keys = {
          public = Config.auth0.client_secret
        }
      })
      if not token
      or token.resource ~= data.resource
      or not token.user
      or not token.permissions
      or not token.permissions.read then
        return
      end

      --
      -- while true do
      --   local message = ws:receive ()
      --   if message then
      --      ws:send (message)
      --   else
      --      ws:close ()
      --      return
      --   end
      -- end
    end
  }
}

Copas.loop ()

print (Colors (Et.render ("%{blue}[<%= time %>]%{reset} Stop editor for %{green}<%= project %>/<%= resource %>%{reset}.", {
  project  = data.project,
  resource = data.resource,
  time     = os.date "%c",
})))
