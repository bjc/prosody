-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


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
httpserver.new_from_config(ports, handle_request);
