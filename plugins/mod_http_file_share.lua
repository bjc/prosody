-- Prosody IM
-- Copyright (C) 2021 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- XEP-0363: HTTP File Upload
-- Again, from the top!

local t_insert = table.insert;
local jid = require "util.jid";
local st = require "util.stanza";
local url = require "socket.url";
local dm = require "core.storagemanager".olddm;
local jwt = require "util.jwt";
local errors = require "util.error";
local dataform = require "util.dataforms".new;
local dt = require "util.datetime";
local hi = require "util.human.units";
local cache = require "util.cache";

local namespace = "urn:xmpp:http:upload:0";

module:depends("disco");

module:add_identity("store", "file", module:get_option_string("name", "HTTP File Upload"));
module:add_feature(namespace);

local uploads = module:open_store("uploads", "archive");
-- id, <request>, time, owner

local secret = module:get_option_string(module.name.."_secret", require"util.id".long());
local external_base_url = module:get_option_string(module.name .. "_base_url");
local file_size_limit = module:get_option_number(module.name .. "_size_limit", 10 * 1024 * 1024); -- 10 MB
local file_types = module:get_option_set(module.name .. "_allowed_file_types", {});
local safe_types = module:get_option_set(module.name .. "_safe_file_types", {"image/*","video/*","audio/*","text/plain"});
local expiry = module:get_option_number(module.name .. "_expires_after", 7 * 86400);
local daily_quota = module:get_option_number(module.name .. "_daily_quota", file_size_limit*10); -- 100 MB / day

local access = module:get_option_set(module.name .. "_access", {});

if not external_base_url then
	module:depends("http");
end

module:add_extension(dataform {
	{ name = "FORM_TYPE", type = "hidden", value = namespace },
	{ name = "max-file-size", type = "text-single" },
}:form({ ["max-file-size"] = tostring(file_size_limit) }, "result"));

local upload_errors = errors.init(module.name, namespace, {
	access = { type = "auth"; condition = "forbidden" };
	filename = { type = "modify"; condition = "bad-request"; text = "Invalid filename" };
	filetype = { type = "modify"; condition = "not-acceptable"; text = "File type not allowed" };
	filesize = { type = "modify"; condition = "not-acceptable"; text = "File too large";
		extra = {tag = st.stanza("file-too-large", {xmlns = namespace}):tag("max-file-size"):text(tostring(file_size_limit)) };
	};
	filesizefmt = { type = "modify"; condition = "bad-request"; text = "File size must be positive integer"; };
	quota = { type = "wait"; condition = "resource-constraint"; text = "Daily quota reached"; };
});

local upload_cache = cache.new(1024);
local quota_cache = cache.new(1024);

-- Convenience wrapper for logging file sizes
local function B(bytes) return hi.format(bytes, "B", "b"); end

local function get_filename(slot, create)
	return dm.getpath(slot, module.host, module.name, "bin", create)
end

function get_daily_quota(uploader)
	local now = os.time();
	local max_age = now - 86400;
	local cached = quota_cache:get(uploader);
	if cached and cached.time > max_age then
		return cached.size;
	end
	local iter, err = uploads:find(nil, {with = uploader; start = max_age });
	if not iter then return iter, err; end
	local total_bytes = 0;
	local oldest_upload = now;
	for _, slot, when in iter do
		local size = tonumber(slot.attr.size);
		if size then total_bytes = total_bytes + size; end
		if when < oldest_upload then oldest_upload = when; end
	end
	-- If there were no uploads then we end up caching [now, 0], which is fine
	-- since we increase the size on new uploads
	quota_cache:set(uploader, { time = oldest_upload, size = total_bytes });
	return total_bytes;
end

function may_upload(uploader, filename, filesize, filetype) -- > boolean, error
	local uploader_host = jid.host(uploader);
	if not ((access:empty() and prosody.hosts[uploader_host]) or access:contains(uploader) or access:contains(uploader_host)) then
		return false, upload_errors.new("access");
	end

	if not filename or filename:find"/" then
		-- On Linux, only '/' and '\0' are invalid in filenames and NUL can't be in XML
		return false, upload_errors.new("filename");
	end

	if not filesize or filesize < 0 or filesize % 1 ~= 0 then
		return false, upload_errors.new("filesizefmt");
	end
	if filesize > file_size_limit then
		return false, upload_errors.new("filesize");
	end

	local uploader_quota = get_daily_quota(uploader);
	if uploader_quota + filesize > daily_quota then
		return false, upload_errors.new("quota");
	end

	if not ( file_types:empty() or file_types:contains(filetype) or file_types:contains(filetype:gsub("/.*", "/*")) ) then
		return false, upload_errors.new("filetype");
	end

	return true;
end

function get_authz(slot, uploader, filename, filesize, filetype)
	return jwt.sign(secret, {
		sub = uploader;
		filename = filename;
		filesize = filesize;
		filetype = filetype;
		slot = slot;
		exp = os.time()+300;
	});
end

function get_url(slot, filename)
	local base_url = external_base_url or module:http_url();
	local slot_url = url.parse(base_url);
	slot_url.path = url.parse_path(slot_url.path or "/");
	t_insert(slot_url.path, slot);
	if filename then
		t_insert(slot_url.path, filename);
		slot_url.path.is_directory = false;
	else
		slot_url.path.is_directory = true;
	end
	slot_url.path = url.build_path(slot_url.path);
	return url.build(slot_url);
end

function handle_slot_request(event)
	local stanza, origin = event.stanza, event.origin;

	local request = st.clone(stanza.tags[1], true);
	local filename = request.attr.filename;
	local filesize = tonumber(request.attr.size);
	local filetype = request.attr["content-type"] or "application/octet-stream";
	local uploader = jid.bare(stanza.attr.from);

	local may, why_not = may_upload(uploader, filename, filesize, filetype);
	if not may then
		origin.send(st.error_reply(stanza, why_not));
		return true;
	end

	module:log("info", "Issuing upload slot to %s for %s", uploader, B(filesize));
	local slot, storage_err = errors.coerce(uploads:append(nil, nil, request, os.time(), uploader))
	if not slot then
		origin.send(st.error_reply(stanza, storage_err));
		return true;
	end

	local cached_quota = quota_cache:get(uploader);
	if cached_quota and cached_quota.time > os.time()-86400 then
		cached_quota.size = cached_quota.size + filesize;
		quota_cache:set(uploader, cached_quota);
	end

	local authz = get_authz(slot, uploader, filename, filesize, filetype);
	local slot_url = get_url(slot, filename);
	local upload_url = slot_url;

	local reply = st.reply(stanza)
		:tag("slot", { xmlns = namespace })
			:tag("get", { url = slot_url }):up()
			:tag("put", { url = upload_url })
				:text_tag("header", "Bearer "..authz, {name="Authorization"})
		:reset();

	origin.send(reply);
	return true;
end

function handle_upload(event, path) -- PUT /upload/:slot
	local request = event.request;
	local authz = request.headers.authorization;
	if authz then
		authz = authz:match("^Bearer (.*)")
	end
	if not authz then
		module:log("debug", "Missing or malformed Authorization header");
		event.response.headers.www_authenticate = "Bearer";
		return 403;
	end
	local authed, upload_info = jwt.verify(secret, authz);
	if not (authed and type(upload_info) == "table" and type(upload_info.exp) == "number") then
		module:log("debug", "Unauthorized or invalid token: %s, %q", authed, upload_info);
		return 401;
	end
	if not request.body_sink and upload_info.exp < os.time() then
		module:log("debug", "Authorization token expired on %s", dt.datetime(upload_info.exp));
		return 410;
	end
	if not path or upload_info.slot ~= path:match("^[^/]+") then
		module:log("debug", "Invalid upload slot: %q, path: %q", upload_info.slot, path);
		return 400;
	end
	if request.headers.content_length and tonumber(request.headers.content_length) ~= upload_info.filesize then
		return 413;
		-- Note: We don't know the size if the upload is streamed in chunked encoding,
		-- so we also check the final file size on completion.
	end

	local filename = get_filename(upload_info.slot, true);


	if not request.body_sink then
		module:log("debug", "Preparing to receive upload into %q, expecting %s", filename, B(upload_info.filesize));
		local fh, err = errors.coerce(io.open(filename.."~", "w"));
		if not fh then
			return err;
		end
		request.body_sink = fh;
		if request.body == false then
			return true;
		end
	end

	if request.body then
		module:log("debug", "Complete upload available, %s", B(#request.body));
		-- Small enough to have been uploaded already
		local written, err = errors.coerce(request.body_sink:write(request.body));
		if not written then
			return err;
		end
		request.body = nil;
	end

	if request.body_sink then
		local final_size = request.body_sink:seek();
		local uploaded, err = errors.coerce(request.body_sink:close());
		if final_size ~= upload_info.filesize then
			-- Could be too short as well, but we say the same thing
			uploaded, err = false, 413;
		end
		if uploaded then
			module:log("debug", "Upload of %q completed, %s", filename, B(final_size));
			assert(os.rename(filename.."~", filename));

			upload_cache:set(upload_info.slot, {
					name = upload_info.filename;
					size = tostring(upload_info.filesize);
					type = upload_info.filetype;
					time = os.time();
				});
			return 201;
		else
			assert(os.remove(filename.."~"));
			return err;
		end
	end

end

function handle_download(event, path) -- GET /uploads/:slot+filename
	local request, response = event.request, event.response;
	local slot_id = path:match("^[^/]+");
	local basename, filetime, filetype, filesize;
	local cached = upload_cache:get(slot_id);
	if cached then
		module:log("debug", "Cache hit");
		-- TODO stats (instead of logging?)
		basename = cached.name;
		filesize = cached.size;
		filetype = cached.type;
		filetime = cached.time;
		upload_cache:set(slot_id, cached);
		-- TODO cache negative hits?
	else
		module:log("debug", "Cache miss");
		local slot, when = errors.coerce(uploads:get(nil, slot_id));
		if not slot then
			module:log("debug", "uploads:get(%q) --> not-found, %s", slot_id, when);
		else
			module:log("debug", "uploads:get(%q) --> %s, %d", slot_id, slot, when);
			basename = slot.attr.filename;
			filesize = slot.attr.size;
			filetype = slot.attr["content-type"];
			filetime = when;
			upload_cache:set(slot_id, {
					name = basename;
					size = slot.attr.size;
					type = filetype;
					time = when;
				});
		end
	end
	if not basename then
		return 404;
	end
	local last_modified = os.date('!%a, %d %b %Y %H:%M:%S GMT', filetime);
	if request.headers.if_modified_since == last_modified then
		return 304;
	end
	local filename = get_filename(slot_id);
	local handle, ferr = errors.coerce(io.open(filename));
	if not handle then
		return ferr or 410;
	end

	local disposition = "attachment";
	if safe_types:contains(filetype) or safe_types:contains(filetype:gsub("/.*", "/*")) then
		disposition = "inline";
	end

	response.headers.last_modified = last_modified;
	response.headers.content_length = filesize;
	response.headers.content_type = filetype or "application/octet-stream";
	response.headers.content_disposition = string.format("%s; filename=%q", disposition, basename);

	response.headers.cache_control = "max-age=31556952, immutable";
	response.headers.content_security_policy =  "default-src 'none'; frame-ancestors 'none';"
	response.headers.strict_transport_security = "max-age=31556952";
	response.headers.x_content_type_options = "nosniff";
	response.headers.x_frame_options = "DENY"; -- replaced by frame-ancestors in CSP?
	response.headers.x_xss_protection = "1; mode=block";

	return response:send_file(handle);
end

if expiry >= 0 and not external_base_url then
	-- TODO HTTP DELETE to the external endpoint?
	local array = require "util.array";
	local async = require "util.async";
	local ENOENT = require "util.pposix".ENOENT;

	local function sleep(t)
		local wait, done = async.waiter();
		module:add_timer(t, done)
		wait();
	end

	local reaper_task = async.runner(function(boundary_time)
		local iter, total = assert(uploads:find(nil, {["end"] = boundary_time; total = true}));

		if total == 0 then
			module:log("info", "No expired uploaded files to prune");
			return;
		end

		module:log("info", "Pruning expired files uploaded earlier than %s", dt.datetime(boundary_time));

		local obsolete_files = array();
		local i = 0;
		for slot_id in iter do
			i = i + 1;
			obsolete_files:push(get_filename(slot_id));
			upload_cache:set(slot_id, nil);
		end

		sleep(0.1);
		local n = 0;
		obsolete_files:filter(function(filename)
			n = n + 1;
			if i % 100 == 0 then sleep(0.1); end
			local deleted, err, errno = os.remove(filename);
			if deleted or errno == ENOENT then
				return false;
			else
				module:log("error", "Could not delete file %q: %s", filename, err);
				return true;
			end
		end);

		local deletion_query = {["end"] = boundary_time};
		if #obsolete_files == 0 then
			module:log("info", "All %d expired files deleted", n);
		else
			module:log("warn", "%d out of %d expired files could not be deleted", #obsolete_files, n);
			deletion_query = {ids = obsolete_files};
		end

		local removed, err = uploads:delete(nil, deletion_query);

		if removed == true or removed == n or removed == #obsolete_files then
			module:log("debug", "Removed all metadata for expired uploaded files");
		else
			module:log("error", "Problem removing metadata for deleted files: %s", err);
		end

	end);

	module:add_timer(1, function ()
		reaper_task:run(os.time()-expiry);
		return 60*60;
	end);
end

module:hook("iq-get/host/urn:xmpp:http:upload:0:request", handle_slot_request);

if not external_base_url then
module:provides("http", {
		streaming_uploads = true;
		route = {
			["PUT /*"] = handle_upload;
			["GET /*"] = handle_download;
		}
	});
end
