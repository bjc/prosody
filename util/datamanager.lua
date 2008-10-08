local format = string.format;
local setmetatable, type = setmetatable, type;
local pairs = pairs;
local char = string.char;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local log = log;
local io_open = io.open;

module "datamanager"


---- utils -----
local encode, decode;

local log = function (type, msg) return log(type, "datamanager", msg); end

do 
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%x", c:byte()); end));
	end
end

local function basicSerialize (o)
  if type(o) == "number" or type(o) == "boolean" then
    return tostring(o)
  else -- assume it is a string
    return string.format("%q", tostring(o))
  end
end


local function simplesave (f, o)
      if type(o) == "number" then
        f:write(o)
      elseif type(o) == "string" then
        f:write(format("%q", o))
      elseif type(o) == "table" then
        f:write("{\n")
        for k,v in pairs(o) do
          f:write(" [", basicSerialize(k), "] = ")
          simplesave(f, v)
          f:write(",\n")
        end
        f:write("}\n")
      else
        error("cannot serialize a " .. type(o))
      end
    end
  
------- API -------------

function getpath(username, host, datastore)
	return format("data/%s/%s/%s.dat", encode(host), datastore, encode(username));
end

function load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore));
	if not data then log("warn", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..username.."@"..host); return nil; end
	setfenv(data, {});
	local success, ret = pcall(data);
	if not success then log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..username.."@"..host); return nil; end
	return ret;
end

function store(username, host, datastore, data)
	local f, msg = io_open(getpath(username, host, datastore), "w+");
	if not f then log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..username.."@"..host); return nil; end
	f:write("return ");
	simplesave(f, data);
	f:close();
	return true;
end

