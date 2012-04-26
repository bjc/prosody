-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("http");
local lfs = require "lfs";

local open = io.open;
local stat = lfs.attributes;

local http_base = module:get_option_string("http_files_dir", module:get_option_string("http_path", "www_files"));

-- TODO: Should we read this from /etc/mime.types if it exists? (startup time...?)
local mime_map = {
	html = "text/html";
	htm = "text/html";
	xml = "text/xml";
	xsl = "text/xml";
	txt = "text/plain; charset=utf-8";
	js = "text/javascript";
	css = "text/css";
};

function serve_file(event, path)
	local response = event.response;
	local full_path = http_base.."/"..path;
	if stat(full_path, "mode") == "directory" then
		if stat(full_path.."/index.html", "mode") == "file" then
			return serve_file(event, path.."/index.html");
		end
		return 403;
	end
	local f, err = open(full_path, "rb");
	if not f then
		module:log("warn", "Failed to open file: %s", err);
		return 404;
	end
	local data = f:read("*a");
	f:close();
	if not data then
		return 403;
	end
	local ext = path:match("%.([^.]*)$");
	response.headers.content_type = mime_map[ext]; -- Content-Type should be nil when not known
	return response:send(data);
end

module:provides("http", {
	route = {
		["/*"] = serve_file;
	};
});

