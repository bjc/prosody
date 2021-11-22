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
local lfs = require "lfs";

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
local total_storage_limit = module:get_option_number(module.name.."_global_quota", nil);

local access = module:get_option_set(module.name .. "_access", {});

if not external_base_url then
	module:depends("http");
end

module:add_extension(dataform {
	{ name = "FORM_TYPE", type = "hidden", value = namespace },
	{ name = "max-file-size", type = "text-single", datatype = "xs:integer" },
}:form({ ["max-file-size"] = file_size_limit }, "result"));

local upload_errors = errors.init(module.name, namespace, {
	access = { type = "auth"; condition = "forbidden" };
	filename = { type = "modify"; condition = "bad-request"; text = "Invalid filename" };
	filetype = { type = "modify"; condition = "not-acceptable"; text = "File type not allowed" };
	filesize = { type = "modify"; condition = "not-acceptable"; text = "File too large";
		extra = {tag = st.stanza("file-too-large", {xmlns = namespace}):tag("max-file-size"):text(tostring(file_size_limit)) };
	};
	filesizefmt = { type = "modify"; condition = "bad-request"; text = "File size must be positive integer"; };
	quota = { type = "wait"; condition = "resource-constraint"; text = "Daily quota reached"; };
	unknowntotal = { type = "wait"; condition = "undefined-condition"; text = "Server storage usage not yet calculated" };
	outofdisk = { type = "wait"; condition = "resource-constraint"; text = "Server global storage quota reached" };
});

local upload_cache = cache.new(1024);
local quota_cache = cache.new(1024);

local total_storage_usage = nil;

local measure_upload_cache_size = module:measure("upload_cache", "amount");
local measure_quota_cache_size = module:measure("quota_cache", "amount");
local measure_total_storage_usage = nil;
if total_storage_limit then
	measure_total_storage_usage = module:measure("total_storage", "amount", { unit = "bytes" });
end

module:hook_global("stats-update", function ()
	measure_upload_cache_size(upload_cache:count());
	measure_quota_cache_size(quota_cache:count());
	if total_storage_limit then
		measure_total_storage_usage(total_storage_usage);
	end
end);

local buckets = {};
for n = 10, 40, 2 do
	local exp = math.floor(2 ^ n);
	table.insert(buckets, exp);
	if exp >= file_size_limit then break end
end
local measure_uploads = module:measure("upload", "sizes", {buckets = buckets});

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

	if total_storage_limit then
		if not total_storage_usage  then
			return false, upload_errors.new("unknowntotal");
		elseif total_storage_usage + filesize > total_storage_limit then
			module:log("warn", "Global storage quota reached, at %s!", B(total_storage_usage));
			return false, upload_errors.new("outofdisk");
		end
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
local now = os.time();
	return jwt.sign(secret, {
		-- token properties
		sub = uploader;
		iat = now;
		exp = now+300;

		-- slot properties
		slot = slot;
		expires = expiry >= 0 and (now+expiry) or nil;
		-- file properties
		filename = filename;
		filesize = filesize;
		filetype = filetype;
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

	if total_storage_usage then
		total_storage_usage = total_storage_usage + filesize;
		module:log("debug", "Global quota %s / %s", B(total_storage_usage), B(total_storage_limit));
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
		return 401;
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

	do
		-- check if upload has been completed already
		-- we want to allow retry of a failed upload attempt, but not after it's been completed
		local f = io.open(filename, "r");
		if f then
			f:close();
			return 409;
		end
	end

	if not request.body_sink then
		module:log("debug", "Preparing to receive upload into %q, expecting %s", filename, B(upload_info.filesize));
		local fh, err = io.open(filename.."~", "w");
		if not fh then
			module:log("error", "Could not open file for writing: %s", err);
			return 500;
		end
		function event.response:on_destroy() -- luacheck: ignore 212/self
			-- Clean up incomplete upload
			if io.type(fh) == "file" then -- still open
				fh:close();
				os.remove(filename.."~");
			end
		end
		request.body_sink = fh;
		if request.body == false then
			if request.headers.expect == "100-continue" then
				request.conn:write("HTTP/1.1 100 Continue\r\n\r\n");
			end
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
			measure_uploads(final_size);

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

local download_cache_hit = module:measure("download_cache_hit", "rate");
local download_cache_miss = module:measure("download_cache_miss", "rate");

function handle_download(event, path) -- GET /uploads/:slot+filename
	local request, response = event.request, event.response;
	local slot_id = path:match("^[^/]+");
	local basename, filetime, filetype, filesize;
	local cached = upload_cache:get(slot_id);
	if cached then
		module:log("debug", "Cache hit");
		download_cache_hit();
		basename = cached.name;
		filesize = cached.size;
		filetype = cached.type;
		filetime = cached.time;
		upload_cache:set(slot_id, cached);
		-- TODO cache negative hits?
	else
		module:log("debug", "Cache miss");
		download_cache_miss();
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
	local handle, ferr = io.open(filename);
	if not handle then
		module:log("error", "Could not open file for reading: %s", ferr);
		-- This can be because the upload slot wasn't used, or the file disappeared
		-- somehow, or permission issues.
		return 410;
	end

	local request_range = request.headers.range;
	local response_range;
	if request_range then
		local range_start, range_end = request_range:match("^bytes=(%d+)%-(%d*)$")
		-- Only support resumption, ie ranges from somewhere in the middle until the end of the file.
		if (range_start and range_start ~= "0") and (range_end == "" or range_end == filesize) then
			local pos, size = tonumber(range_start), tonumber(filesize);
			local new_pos = pos < size and handle:seek("set", pos);
			if new_pos and new_pos < size then
				response_range = "bytes "..range_start.."-"..filesize.."/"..filesize;
				filesize = string.format("%d", size-pos);
			else
				handle:close();
				return 416;
			end
		end
	end


	if not filetype then
		filetype = "application/octet-stream";
	end
	local disposition = "attachment";
	if safe_types:contains(filetype) or safe_types:contains(filetype:gsub("/.*", "/*")) then
		disposition = "inline";
	end

	response.headers.last_modified = last_modified;
	response.headers.content_length = filesize;
	response.headers.content_type = filetype;
	response.headers.content_disposition = string.format("%s; filename=%q", disposition, basename);

	if response_range then
		response.status_code = 206;
		response.headers.content_range = response_range;
	end
	response.headers.accept_ranges = "bytes";

	response.headers.cache_control = "max-age=31556952, immutable";
	response.headers.content_security_policy =  "default-src 'none'; frame-ancestors 'none';"
	response.headers.strict_transport_security = "max-age=31556952";
	response.headers.x_content_type_options = "nosniff";
	response.headers.x_frame_options = "DENY"; -- COMPAT IE missing support for CSP frame-ancestors
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

	local prune_start = module:measure("prune", "times");

	module:daily("Remove expired files", function(_, boundary_time)
		local prune_done = prune_start();
		local iter, total = assert(uploads:find(nil, {["end"] = boundary_time; total = true}));

		if total == 0 then
			module:log("info", "No expired uploaded files to prune");
			prune_done();
			return;
		end

		module:log("info", "Pruning expired files uploaded earlier than %s", dt.datetime(boundary_time));
		if total_storage_usage then
			module:log("debug", "Global quota %s / %s", B(total_storage_usage), B(total_storage_limit));
		elseif total_storage_limit then
			module:log("debug", "Global quota %s / %s", "not yet calculated", B(total_storage_limit));
		end

		local obsolete_uploads = array();
		local i = 0;
		local size_sum = 0;
		for slot_id, slot_info in iter do
			i = i + 1;
			obsolete_uploads:push(slot_id);
			upload_cache:set(slot_id, nil);
			size_sum = size_sum + tonumber(slot_info.attr.size);
		end

		sleep(0.1);
		local n = 0;
		local problem_deleting = false;
		obsolete_uploads:filter(function(slot_id)
			n = n + 1;
			if i % 100 == 0 then sleep(0.1); end
			local filename = get_filename(slot_id);
			local deleted, err, errno = os.remove(filename);
			if deleted or errno == ENOENT then
				return true;
			else
				module:log("error", "Could not delete file %q: %s", filename, err);
				problem_deleting = true;
				return false;
			end
		end);
		-- obsolete_uploads now contains slot ids for which the files have been
		-- deleted and that needs to be cleared from the database

		local deletion_query = {["end"] = boundary_time};
		if not problem_deleting then
			module:log("info", "All (%d, %s) expired files successfully deleted", n, B(size_sum));
			if total_storage_usage then
				total_storage_usage = total_storage_usage - size_sum;
				module:log("debug", "Global quota %s / %s", B(total_storage_usage), B(total_storage_limit));
			end
			-- we can delete based on time
		else
			module:log("warn", "%d out of %d expired files could not be deleted", n-#obsolete_uploads, n);
			-- we'll need to delete only those entries where the files were
			-- successfully deleted, and then try again with the failed ones.
			-- eventually the admin ought to notice and fix the permissions or
			-- whatever the problem is.
			-- total_storage_limit will be inaccurate until this has been resolved
			deletion_query = {ids = obsolete_uploads};
		end

		if #obsolete_uploads == 0 then
			module:log("debug", "No metadata to remove");
		else
			local removed, err = uploads:delete(nil, deletion_query);

			if removed == true or removed == n or removed == #obsolete_uploads then
				module:log("debug", "Removed all metadata for expired uploaded files");
			else
				module:log("error", "Problem removing metadata for deleted files: %s", err);
			end
		end

		prune_done();
	end);
end

if total_storage_limit then
	local summary_start = module:measure("summary", "times");

	module:daily("Global quota check", function()
		local summary_done = summary_start();
		local iter = assert(uploads:find(nil));

		local count, sum = 0, 0;
		for _, file in iter do
			sum = sum + tonumber(file.attr.size);
			count = count + 1;
		end

		module:log("info", "Uploaded files total: %s in %d files", B(sum), count);
		total_storage_usage = sum;
		module:log("debug", "Global quota %s / %s", B(total_storage_usage), B(total_storage_limit));
		summary_done();
	end);

end

-- Reachable from the console
function check_files(query)
	local issues = {};
	local iter = assert(uploads:find(nil, query));
	for slot_id, file in iter do
		local filename = get_filename(slot_id);
		local size, err = lfs.attributes(filename, "size");
		if not size then
			issues[filename] = err;
		elseif tonumber(file.attr.size) ~= size then
			issues[filename] = "file size mismatch";
		end
	end

	return next(issues) == nil, issues;
end

module:hook("iq-get/host/urn:xmpp:http:upload:0:request", handle_slot_request);

if not external_base_url then
module:provides("http", {
		streaming_uploads = true;
		cors = {
			credentials = true;
			headers = {
				Authorization = true;
			};
		};
		route = {
			["PUT /*"] = handle_upload;
			["GET /*"] = handle_download;
			["GET /"] = function (event)
				return prosody.events.fire_event("http-message", {
						response = event.response;
						---
						title = "Prosody HTTP Upload endpoint";
						message = "This is where files will be uploaded to, and served from.";
						warning = not (event.request.secure) and "This endpoint is not considered secure!" or nil;
					}) or "This is the Prosody HTTP Upload endpoint.";
			end
		}
	});
end
