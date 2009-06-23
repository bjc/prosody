
local httpserver = require "net.httpserver";

local open = io.open;
local t_concat = table.concat;

local http_base = "www_files";

local response_404 = { status = "404 Not Found", body = "<h1>Page Not Found</h1>Sorry, we couldn't find what you were looking for :(" };

local http_path = { http_base };
local function handle_request(method, body, request)
	local path = request.url.path:gsub("%.%.%/", ""):gsub("^/[^/]+", "");
	http_path[2] = path;
	local f, err = open(t_concat(http_path), "r");
	if not f then return response_404; end
	local data = f:read("*a");
	f:close();
	return data;
end

local ports = config.get(module.host, "core", "http_ports") or { 5280 };
for _, options in ipairs(ports) do
	local port, base, ssl, interface = 5280, "files", false, nil;
	if type(options) == "number" then
		port = options;
	elseif type(options) == "table" then
		port, base, ssl, interface = options.port or 5280, options.path or "files", options.ssl or false, options.interface;
	elseif type(options) == "string" then
		base = options;
	end
	httpserver.new{ port = port, base = base, handler = handle_request, ssl = ssl }
end
