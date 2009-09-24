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

local http_base = config.get("*", "core", "http_path") or "www_files";

local response_400 = { status = "400 Bad Request", body = "<h1>Bad Request</h1>Sorry, we didn't understand your request :(" };
local response_404 = { status = "404 Not Found", body = "<h1>Page Not Found</h1>Sorry, we couldn't find what you were looking for :(" };

local function preprocess_path(path)
	if path:sub(1,1) ~= "/" then
		path = "/"..path;
	end
	local level = 0;
	for component in path:gmatch("([^/]+)/") do
		if component == ".." then
			level = level - 1;
		elseif component ~= "." then
			level = level + 1;
		end
		if level < 0 then
			return nil;
		end
	end
	return path;
end

function serve_file(path)
	local f, err = open(http_base..path, "r");
	if not f then return response_404; end
	local data = f:read("*a");
	f:close();
	return data;
end

local function handle_file_request(method, body, request)
	local path = preprocess_path(request.url.path);
	if not path then return response_400; end
	path = path:gsub("^/[^/]+", ""); -- Strip /files/
	return serve_file(path);
end

local function handle_default_request(method, body, request)
	local path = preprocess_path(request.url.path);
	if not path then return response_400; end
	return serve_file(path);
end

local ports = config.get(module.host, "core", "http_ports") or { 5280 };
httpserver.set_default_handler(handle_default_request);
httpserver.new_from_config(ports, "files", handle_file_request);
