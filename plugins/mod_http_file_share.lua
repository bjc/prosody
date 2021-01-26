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

local namespace = "urn:xmpp:http:upload:0";

module:depends("disco");

module:add_identity("store", "file", module:get_option_string("name", "HTTP File Upload"));
module:add_feature(namespace);

local uploads = module:open_store("uploads", "archive");
-- id, <request>, time, owner

local secret = module:get_option_string(module.name.."_secret", require"util.id".long());
local external_base_url = module:get_option_string(module.name .. "_base_url");

local access = module:get_option_set(module.name .. "_access", {});

if not external_base_url then
	module:depends("http");
end

function may_upload(uploader, filename, filesize, filetype) -- > boolean, error
	local uploader_host = jid.host(uploader);
	if not ((access:empty() and prosody.hosts[uploader_host]) or access:contains(uploader) or access:contains(uploader_host)) then
		return false;
	end

	return true;
end

function get_authz(uploader, filename, filesize, filetype, slot)
	return "Bearer "..jwt.sign(secret, {
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
	local filetype = request.attr["content-type"];
	local uploader = jid.bare(stanza.attr.from);

	local may, why_not = may_upload(uploader, filename, filesize, filetype);
	if not may then
		origin.send(st.error_reply(stanza, why_not));
		return true;
	end

	local slot, storage_err = errors.coerce(uploads:append(nil, nil, request, os.time(), uploader))
	if not slot then
		origin.send(st.error_reply(stanza, storage_err));
		return true;
	end

	local authz = get_authz(uploader, filename, filesize, filetype, slot);
	local slot_url = get_url(slot, filename);
	local upload_url = slot_url;

	local reply = st.reply(stanza)
		:tag("slot", { xmlns = namespace })
			:tag("get", { url = slot_url }):up()
			:tag("put", { url = upload_url })
				:text_tag("header", authz, {name="Authorization"})
		:reset();

	origin.send(reply);
	return true;
end

function handle_upload(event, path) -- PUT /upload/:slot
	local request = event.request;
	local authz = request.headers.authorization;
	if not authz or not authz:find"^Bearer ." then
		return 403;
	end
	local authed, upload_info = jwt.verify(secret, authz:match("^Bearer (.*)"));
	if not (authed and type(upload_info) == "table" and type(upload_info.exp) == "number") then
		return 401;
	end
	if upload_info.exp < os.time() then
		return 410;
	end
	if not path or upload_info.slot ~= path:match("^[^/]+") then
		return 400;
	end

	local filename = dm.getpath(upload_info.slot, module.host, module.name, nil, true);

	if not request.body_sink then
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
		local written, err = errors.coerce(request.body_sink:write(request.body));
		if not written then
			return err;
		end
		request.body = nil;
	end

	if request.body_sink then
		local uploaded, err = errors.coerce(request.body_sink:close());
		if uploaded then
			assert(os.rename(filename.."~", filename));
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
	-- TODO cache
	local slot, when = errors.coerce(uploads:get(nil, slot_id));
	if not slot then
		module:log("debug", "uploads:get(%q) --> not-found, %s", slot_id, when);
		return 404;
	end
	module:log("debug", "uploads:get(%q) --> %s, %d", slot_id, slot, when);
	local last_modified = os.date('!%a, %d %b %Y %H:%M:%S GMT', when);
	if request.headers.if_modified_since == last_modified then
		return 304;
	end
	local filename = dm.getpath(slot_id, module.host, module.name);
	local handle, ferr = errors.coerce(io.open(filename));
	if not handle then
		return ferr or 410;
	end
	response.headers.last_modified = last_modified;
	response.headers.content_length = slot.attr.size;
	response.headers.content_type = slot.attr["content-type"];
	response.headers.content_disposition = string.format("attachment; filename=%q", slot.attr.filename);

	response.headers.cache_control = "max-age=31556952, immutable";
	response.headers.content_security_policy =  "default-src 'none'; frame-ancestors 'none';"

	return response:send_file(handle);
	-- TODO
	-- Set security headers
end

-- TODO periodic cleanup job

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
