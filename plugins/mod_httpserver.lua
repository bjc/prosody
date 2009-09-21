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
local check_http_path;

local http_base = config.get("*", "core", "http_path") or "www_files";

local response_403 = { status = "403 Forbidden", body = "<h1>Invalid URL</h1>Sorry, we couldn't find what you were looking for :(" };
local response_404 = { status = "404 Not Found", body = "<h1>Page Not Found</h1>Sorry, we couldn't find what you were looking for :(" };

local http_path = { http_base };
local function handle_request(method, body, request)
	local path = check_http_path(request.url.path:gsub("^/[^/]+%.*", ""));
	if not path then
		return response_403;
	end
	http_path[2] = path;
	local f, err = open(t_concat(http_path), "r");
	if not f then return response_404; end
	local data = f:read("*a");
	f:close();
	return data;
end

local ports = config.get(module.host, "core", "http_ports") or { 5280 };
httpserver.new_from_config(ports, "files", handle_request);

function check_http_path(url)
	if url:sub(1,1) ~= "/" then
		url = "/"..url;
	end
	
	local level = 0;
	for part in url:gmatch("%/([^/]+)") do
		if part == ".." then
			level = level - 1;
		elseif part ~= "." then
			level = level + 1;
		end
		if level < 0 then
			return nil;
		end
	end
	return url;
end
