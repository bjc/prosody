local format = string.format;
local setmetatable, type = setmetatable, type;
local pairs = pairs;
local char = string.char;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local log = log;
local io_open = io.open;
local os_remove = os.remove;
local tostring = tostring;
local error = error;
local next = next;

local indent = function(f, i)
	for n = 1, i do
		f:write("\t");
	end
end

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
		return tostring(o);
	else -- assume it is a string -- FIXME make sure it's a string. throw an error otherwise.
		return (format("%q", tostring(o)):gsub("\\\n", "\\n"));
	end
end


local function simplesave (f, o, ind)
	if type(o) == "number" then
		f:write(o)
	elseif type(o) == "string" then
		f:write((format("%q", o):gsub("\\\n", "\\n")))
	elseif type(o) == "table" then
		f:write("{\n")
		for k,v in pairs(o) do
			indent(f, ind);
			f:write("[", basicSerialize(k), "] = ")
			simplesave(f, v, ind+1)
			f:write(",\n")
		end
		indent(f, ind-1);
		f:write("}")
	elseif type(o) == "boolean" then
		f:write(o and "true" or "false");
	else
		error("cannot serialize a " .. type(o))
	end
end

------- API -------------

function getpath(username, host, datastore)
	if username then
		return format("data/%s/%s/%s.dat", encode(host), datastore, encode(username));
	elseif host then
		return format("data/%s/%s.dat", encode(host), datastore);
	else
		return format("data/%s.dat", datastore);
	end
end

function load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore));
	if not data then
		log("warn", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	setfenv(data, {});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	return ret;
end

function store(username, host, datastore, data)
	if not data then
		data = {};
	end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("return ");
	simplesave(f, data, 1);
	f:close();
	if not next(data) then -- try to delete empty datastore
		os_remove(getpath(username, host, datastore));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

return _M;