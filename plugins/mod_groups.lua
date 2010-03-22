-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local groups;
local members;

local groups_file;

local jid, datamanager = require "util.jid", require "util.datamanager";
local jid_bare, jid_prep = jid.bare, jid.prep;

local module_host = module:get_host();

function inject_roster_contacts(username, host, roster)
	module:log("warn", "Injecting group members to roster");
	local bare_jid = username.."@"..host;
	if not members[bare_jid] and not members[false] then return; end -- Not a member of any groups
	
	local function import_jids_to_roster(group_name)
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

	-- Find groups this JID is a member of
	if members[bare_jid] then
		for _, group_name in ipairs(members[bare_jid]) do
			module:log("debug", "Importing group %s", group_name);
			import_jids_to_roster(group_name);
		end
	end
	
	-- Import public groups
	if members[false] then
		for _, group_name in ipairs(members[false]) do
			module:log("debug", "Importing group %s", group_name);
			import_jids_to_roster(group_name);
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
	members = { [false] = {} };
	local curr_group = "default";
	for line in io.lines(groups_file) do
		if line:match("^%s*%[.-%]%s*$") then
			curr_group = line:match("^%s*%[(.-)%]%s*$");
			if curr_group:match("^%+") then
				curr_group = curr_group:gsub("^%+", "");
				if not members[false] then
					members[false] = {};
				end
				members[false][#members[false]+1] = curr_group; -- Is a public group
			end
			module:log("debug", "New group: %s", tostring(curr_group));
			groups[curr_group] = groups[curr_group] or {};
		else
			-- Add JID
			local jid = jid_prep(line);
			if jid then
				module:log("debug", "New member of %s: %s", tostring(curr_group), tostring(jid));
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
