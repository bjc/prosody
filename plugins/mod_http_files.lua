-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("http");
local lfs = require "lfs";

local os_date = os.date;
local open = io.open;
local stat = lfs.attributes;

local http_base = module:get_option_string("http_files_dir", module:get_option_string("http_path", "www_files"));
local dir_indices = module:get_option("http_files_index", { "index.html", "index.htm" });
local show_file_list = module:get_option_boolean("http_files_show_list");

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

function serve_file(event, path)
	local request, response = event.request, event.response;
	local orig_path = request.path;
	local full_path = http_base.."/"..path;
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

	local data = cache[path];
	if data and data.etag == etag then
		response_headers.content_type = data.content_type;
		data = data.data;
	elseif attr.mode == "directory" then
		if full_path:sub(-1) ~= "/" then
			response_headers.location = orig_path.."/";
			return 301;
		end
		for i=1,#dir_indices do
			if stat(full_path..dir_indices[i], "mode") == "file" then
				return serve_file(event, path..dir_indices[i]);
			end
		end

		if not show_file_list then
			return 403;
		else
			local html = require"util.stanza".stanza("html")
				:tag("head"):tag("title"):text(path):up()
					:tag("meta", { charset="utf-8" }):up()
				:up()
				:tag("body"):tag("h1"):text(path):up()
					:tag("ul");
			for file in lfs.dir(full_path) do
				if file:sub(1,1) ~= "." then
					local attr = stat(full_path..file) or {};
					html:tag("li", { class = attr.mode })
						:tag("a", { href = file }):text(file)
					:up():up();
				end
			end
			data = "<!DOCTYPE html>\n"..tostring(html);
			cache[path] = { data = data, content_type = mime_map.html; etag = etag; };
			response_headers.content_type = mime_map.html;
		end

	else
		local f, err = open(full_path, "rb");
		if f then
			data = f:read("*a");
			f:close();
		end
		if not data then
			return 403;
		end
		local ext = path:match("%.([^./]+)$");
		local content_type = ext and mime_map[ext];
		cache[path] = { data = data; content_type = content_type; etag = etag };
		response_headers.content_type = content_type;
	end

	return response:send(data);
end

module:provides("http", {
	route = {
		["GET /*"] = serve_file;
	};
});

