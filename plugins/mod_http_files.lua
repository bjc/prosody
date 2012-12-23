-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("http");
local server = require"net.http.server";
local lfs = require "lfs";

local os_date = os.date;
local open = io.open;
local stat = lfs.attributes;
local build_path = require"socket.url".build_path;

local base_path = module:get_option_string("http_files_dir", module:get_option_string("http_path"));
local dir_indices = module:get_option("http_index_files", { "index.html", "index.htm" });
local directory_index = module:get_option_boolean("http_dir_listing");

local mime_map = module:shared("mime").types;
if not mime_map then
	mime_map = {
		html = "text/html", htm = "text/html",
		xml = "application/xml",
		txt = "text/plain",
		css = "text/css",
		js = "application/javascript",
		png = "image/png",
		gif = "image/gif",
		jpeg = "image/jpeg", jpg = "image/jpeg",
		svg = "image/svg+xml",
	};
	module:shared("mime").types = mime_map;

	local mime_types, err = open(module:get_option_string("mime_types_file", "/etc/mime.types"),"r");
	if mime_types then
		local mime_data = mime_types:read("*a");
		mime_types:close();
		setmetatable(mime_map, {
			__index = function(t, ext)
				local typ = mime_data:match("\n(%S+)[^\n]*%s"..(ext:lower()).."%s") or "application/octet-stream";
				t[ext] = typ;
				return typ;
			end
		});
	end
end

local cache = setmetatable({}, { __mode = "kv" }); -- Let the garbage collector have it if it wants to.

function serve(opts)
	if type(opts) ~= "table" then -- assume path string
		opts = { path = opts };
	end
	local base_path = opts.path;
	local dir_indices = opts.index_files or dir_indices;
	local directory_index = opts.directory_index;
	local function serve_file(event, path)
		local request, response = event.request, event.response;
		local orig_path = request.path;
		local full_path = base_path .. (path and "/"..path or "");
		local attr = stat(full_path);
		if not attr then
			return 404;
		end

		local request_headers, response_headers = request.headers, response.headers;

		local last_modified = os_date('!%a, %d %b %Y %H:%M:%S GMT', attr.modification);
		response_headers.last_modified = last_modified;

		local etag = ("%02x-%x-%x-%x"):format(attr.dev or 0, attr.ino or 0, attr.size or 0, attr.modification or 0);
		response_headers.etag = etag;

		local if_none_match = request_headers.if_none_match
		local if_modified_since = request_headers.if_modified_since;
		if etag == if_none_match
		or (not if_none_match and last_modified == if_modified_since) then
			return 304;
		end

		local data = cache[orig_path];
		if data and data.etag == etag then
			response_headers.content_type = data.content_type;
			data = data.data;
		elseif attr.mode == "directory" and path then
			if full_path:sub(-1) ~= "/" then
				local path = { is_absolute = true, is_directory = true };
				for dir in orig_path:gmatch("[^/]+") do path[#path+1]=dir; end
				response_headers.location = build_path(path);
				return 301;
			end
			for i=1,#dir_indices do
				if stat(full_path..dir_indices[i], "mode") == "file" then
					return serve_file(event, path..dir_indices[i]);
				end
			end

			if directory_index then
				data = server._events.fire_event("directory-index", { path = request.path, full_path = full_path });
			end
			if not data then
				return 403;
			end
			cache[orig_path] = { data = data, content_type = mime_map.html; etag = etag; };
			response_headers.content_type = mime_map.html;

		else
			local f, err = open(full_path, "rb");
			if f then
				data, err = f:read("*a");
				f:close();
			end
			if not data then
				module:log("debug", "Could not open or read %s. Error was %s", full_path, err);
				return 403;
			end
			local ext = full_path:match("%.([^./]+)$");
			local content_type = ext and mime_map[ext];
			cache[orig_path] = { data = data; content_type = content_type; etag = etag };
			response_headers.content_type = content_type;
		end

		return response:send(data);
	end

	return serve_file;
end

function wrap_route(routes)
	for route,handler in pairs(routes) do
		if type(handler) ~= "function" then
			routes[route] = serve(handler);
		end
	end
	return routes;
end

if base_path then
	module:provides("http", {
		route = {
			["GET /*"] = serve {
				path = base_path;
				directory_index = directory_index;
			}
		};
	});
else
	module:log("debug", "http_files_dir not set, assuming use by some other module");
end

