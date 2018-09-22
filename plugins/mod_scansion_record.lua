local names = { "Romeo", "Juliet", "Mercutio", "Tybalt", "Benvolio" };
local devices = { "", "phone", "laptop", "tablet", "toaster", "fridge", "shoe" };
local users = {};

local full_jids = {};

local id = require "util.id";

local record_file = require "util.datamanager".getpath(id.medium(), module.host, os.date("%Y-%m-%d"), "scs", true);

local fh = io.open(record_file, "w");

local function record(string)
	fh:write(string);
end

local function record_event(session, event)
end

local function record_stanza(stanza, session, verb)
	record(session.scansion_id.." "..verb..":\n\t"..tostring(stanza).."\n\n");
end

local function record_stanza_in(stanza, session)
end

local function record_stanza_out(stanza, session)
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
	local device = user.devices[event.resource];
	if not device then
		user.n_devices = user.n_devices + 1;
		device = devices[user.n_devices] or ("device"..id.short());
		user.devices[event.resource] = device;
	end
	session.scansion_character = user.character;
	session.scansion_device = device;
	session.scansion_id = user.character..(device ~= "" and "'s "..device" or device);

	full_jids[session.full_jid] = session.scansion_id;

	module:log("warn", "Connected: %s's %s", user.character, device);

	filters.add_filter(session, "stanzas/in", record_stanza_in);
	filters.add_filter(session, "stanzas/out", record_stanza_out);
end);

module:hook_global("server-shutdown", function ()
	fh:close();
end);
