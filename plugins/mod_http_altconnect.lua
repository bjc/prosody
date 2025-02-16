-- mod_http_altconnect
-- XEP-0156: Discovering Alternative XMPP Connection Methods

module:depends"http";

local mm = require "prosody.core.modulemanager";
local json = require"prosody.util.json";
local st = require"prosody.util.stanza";
local array = require"prosody.util.array";

local advertise_bosh = module:get_option_boolean("advertise_bosh", true);
local advertise_websocket = module:get_option_boolean("advertise_websocket", true);

local function get_supported()
	local uris = array();
	if advertise_bosh and (mm.is_loaded(module.host, "bosh") or mm.is_loaded("*", "bosh")) then
		uris:push({ rel = "urn:xmpp:alt-connections:xbosh", href = module:http_url("bosh", "/http-bind") });
	end
	if advertise_websocket and (mm.is_loaded(module.host, "websocket") or  mm.is_loaded("*", "websocket")) then
		uris:push({ rel = "urn:xmpp:alt-connections:websocket", href = module:http_url("websocket", "xmpp-websocket"):gsub("^http", "ws") });
	end
	return uris;
end


local function GET_xml(event)
	local response = event.response;
	local xrd = st.stanza("XRD", { xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0' });
	local uris = get_supported();
	for _, method in ipairs(uris) do
		xrd:tag("Link", method):up();
	end
	response.headers.content_type = "application/xrd+xml"
	response.headers.access_control_allow_origin = "*";
	return '<?xml version="1.0" encoding="UTF-8"?>' .. tostring(xrd);
end

local function GET_json(event)
	local response = event.response;
	local jrd = { links = get_supported() };
	response.headers.content_type = "application/json"
	response.headers.access_control_allow_origin = "*";
	return json.encode(jrd);
end;

module:provides("http", {
	default_path = "/.well-known";
	route = {
		["GET /host-meta"] = GET_xml;
		["GET /host-meta.json"] = GET_json;
	};
});
