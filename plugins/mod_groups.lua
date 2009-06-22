
local groups = { default = {} };
local members = {};

local groups_file;

local jid, datamanager = require "util.jid", require "util.datamanager";
local jid_bare, jid_prep = jid.bare, jid.prep;

local module_host = module:get_host();

function inject_roster_contacts(username, host, roster)
	module:log("warn", "Injecting group members to roster");
	local bare_jid = username.."@"..host;
	if not members[bare_jid] then return; end -- Not a member of any groups
	
	-- Find groups this JID is a member of
	for _, group_name in ipairs(members[bare_jid]) do
		-- Find other people in the same group
		for jid in pairs(groups[group_name]) do
			-- Add them to roster
			--module:log("debug", "processing jid %s in group %s", tostring(jid), tostring(group_name));
			if jid ~= bare_jid then
				if not roster[jid] then roster[jid] = {}; end
				roster[jid].subscription = "both";
				if not roster[jid].groups then
					roster[jid].groups = { [group_name] = true };
				end
				roster[jid].groups[group_name] = true;
				roster[jid].persist = false;
			end
		end
	end
end

function remove_virtual_contacts(username, host, datastore, data)
	if host == module_host and datastore == "roster" then
		local new_roster = {};
		for jid, contact in pairs(data) do
			if contact.persist ~= false then
				new_roster[jid] = contact;
			end
		end
		return username, host, datastore, new_roster;
	end

	return username, host, datastore, data;
end

function module.load()
	groups_file = config.get(module:get_host(), "core", "groups_file");
	if not groups_file then return; end
	
	module:hook("roster-load", inject_roster_contacts);
	datamanager.add_callback(remove_virtual_contacts);
	
	groups = { default = {} };
	
	local curr_group = "default";
	for line in io.lines(groups_file) do
		if line:match("^%[%w+%]$") then
			curr_group = line:match("^%[(%w+)%]$");
			groups[curr_group] = groups[curr_group] or {};
		else
			-- Add JID
			local jid = jid_prep(line);
			if jid then
				groups[curr_group][jid] = true;
				members[jid] = members[jid] or {};
				members[jid][#members[jid]+1] = curr_group;
			end
		end
	end
	module:log("info", "Groups loaded successfully");
end

function module.unload()
	datamanager.remove_callback(remove_virtual_contacts);
end
