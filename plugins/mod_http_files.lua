-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("http");

local open = io.open;
local fileserver = require"net.http.files";

local base_path = module:get_option_path("http_files_dir", module:get_option_path("http_path"));
local cache_size = module:get_option_number("http_files_cache_size", 128);
local cache_max_file_size = module:get_option_number("http_files_cache_max_file_size", 4096);
local dir_indices = module:get_option_array("http_index_files", { "index.html", "index.htm" });
local directory_index = module:get_option_boolean("http_dir_listing");

local mime_map = module:shared("/*/http_files/mime").types;
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
	module:shared("/*/http_files/mime").types = mime_map;

	local mime_types, err = open(module:get_option_path("mime_types_file", "/etc/mime.types", "config"), "r");
	if not mime_types then
		module:log("debug", "Could not open MIME database: %s", err);
	else
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

local function get_calling_module()
	local info = debug.getinfo(3, "S");
	if not info then return "An unknown module"; end
	return info.source:match"mod_[^/\\.]+" or info.short_src;
end

-- COMPAT -- TODO deprecate
function serve(opts)
	if type(opts) ~= "table" then -- assume path string
		opts = { path = opts };
	end
	if opts.directory_index == nil then
		opts.directory_index = directory_index;
	end
	if opts.mime_map == nil then
		opts.mime_map = mime_map;
	end
	if opts.cache_size == nil then
		opts.cache_size = cache_size;
	end
	if opts.cache_max_file_size == nil then
		opts.cache_max_file_size = cache_max_file_size;
	end
	if opts.index_files == nil then
		opts.index_files = dir_indices;
	end
	module:log("warn", "%s should be updated to use 'net.http.files' instead of mod_http_files", get_calling_module());
	return fileserver.serve(opts);
end

function wrap_route(routes)
	module:log("debug", "%s should be updated to use 'net.http.files' instead of mod_http_files", get_calling_module());
	for route,handler in pairs(routes) do
		if type(handler) ~= "function" then
			routes[route] = fileserver.serve(handler);
		end
	end
	return routes;
end

module:provides("http", {
	route = {
		["GET /*"] = fileserver.serve({
			path = base_path;
			directory_index = directory_index;
			mime_map = mime_map;
			cache_size = cache_size;
			cache_max_file_size = cache_max_file_size;
			index_files = dir_indices;
		});
	};
});
