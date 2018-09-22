local names = { "Romeo", "Juliet", "Mercutio", "Tybalt", "Benvolio" };
local devices = { "", "phone", "laptop", "tablet", "toaster", "fridge", "shoe" };
local users = {};

local full_jids = {};

local filters = require "util.filters";
local id = require "util.id";
local dt = require "util.datetime";
local dm = require "util.datamanager";

local record_id = id.medium():lower();
local record_date = os.date("%Y%b%d"):lower();
local header_file = dm.getpath(record_id, "scansion", record_date, "sch", true);
local record_file = dm.getpath(record_id, "scansion", record_date, "scs", true);

local head = io.open(header_file, "w");
local scan = io.open(record_file, "w");

local function record(string)
	scan:write(string);
end

local function record_header(string)
	head:write(string);
end

local function record_event(session, event)
	record(session.scansion_id.." "..event.."\n\n");
end

local function record_stanza(stanza, session, verb)
	record(session.scansion_id.." "..verb..":\n\t"..tostring(stanza).."\n\n");
end

local function record_stanza_in(stanza, session)
	if stanza.attr.xmlns == nil then
		record_stanza(stanza, session, "sends")
	end
	return stanza;
end

local function record_stanza_out(stanza, session)
	if stanza.attr.xmlns == nil then
		if not (stanza.name == "iq" and stanza:get_child("bind", "urn:ietf:params:xml:ns:xmpp-bind")) then
			record_stanza(stanza, session, "receives");
		end
	end
	return stanza;
end

module:hook("resource-bind", function (event)
	local session = event.session;
	if not users[session.username] then
		users[session.username] = {
			character = table.remove(names, 1) or id.short();
			devices = {};
			n_devices = 0;
		};
	end
	local user = users[session.username];
	local device = user.devices[session.resource];
	if not device then
		user.n_devices = user.n_devices + 1;
		device = devices[user.n_devices] or ("device"..id.short());
		user.devices[session.resource] = device;
	end
	session.scansion_character = user.character;
	session.scansion_device = device;
	session.scansion_id = user.character..(device ~= "" and "'s "..device or device);

	full_jids[session.full_jid] = session.scansion_id;

	module:log("warn", "Connected: %s's %s", user.character, device);
	record_event(session, "connects");

	filters.add_filter(session, "stanzas/in", record_stanza_in);
	filters.add_filter(session, "stanzas/out", record_stanza_out);
end);

record_header("# mod_scansion_record on host '"..module.host.."' recording started "..dt.datetime().."\n\n");

record[[
-----

]]

module:hook_global("server-stopping", function ()
	record("# recording ended on "..dt.datetime().."\n");
	module:log("info", "Scansion recording available in %s", record_file);
	scan:close();
	head:close()
end);
