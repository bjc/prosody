
local lfs = require "lfs";
local st = require "util.stanza";
local parse_xml = require "util.xml".parse;
local os_getenv = os.getenv;
local io_open = io.open;
local assert = assert;
local ipairs = ipairs;
local coroutine = coroutine;
local print = print;


local function is_dir(path) return lfs.attributes(path, "mode") == "directory"; end
local function is_file(path) return lfs.attributes(path, "mode") == "file"; end
local function clean_path(path)
	return path:gsub("\\", "/"):gsub("//+", "/"):gsub("^~", os_getenv("HOME") or "~");
end

local function load_xml(path)
	local f, err = io_open(path);
	if not f then return f, err; end
	local data = f:read("*a");
	f:close();
	if not data then return; end
	return parse_xml(data);
end

local function load_spool_file(host, filename, path)
	local xml = load_xml(path);
	if not xml then return; end

	local register_element = xml:get_child("query", "jabber:iq:register");
	local username_element = register_element and register_element:get_child("username", "jabber:iq:register");
	local password_element = register_element and register_element:get_child("password", "jabber:iq:auth");
	local username = username_element and username_element:get_text();
	local password = password_element and password_element:get_text();
	if not username then
		print("[warn] Missing /xdb/{jabber:iq:register}register/username> in file "..filename)
		return;
	elseif username..".xml" ~= filename then
		print("[warn] Missing /xdb/{jabber:iq:register}register/username does not match filename "..filename);
		return;
	end

	local userdata = {
		user = username;
		host = host;
		stores = {};
	};
	local stores = userdata.stores;
	stores.accounts = { password = password };

	for i=1,#xml.tags do
		local tag = xml.tags[i];
		local xname = (tag.attr.xmlns or "")..":"..tag.name;
		if tag.attr.j_private_flag == "1" and tag.attr.xmlns then
			-- Private XML
			stores.private = stores.private or {};
			tag.attr.j_private_flag = nil;
			stores.private[tag.attr.xmlns] = st.preserialize(tag);
		elseif xname == "jabber:iq:auth:password" then
			if stores.accounts.password ~= tag:get_text() then
				if password then
					print("[warn] conflicting passwords")
				else
					stores.accounts.password = tag:get_text();
				end
			end
		elseif xname == "jabber:iq:register:query" then
			-- already processed
		elseif xname == "jabber:xdb:nslist:foo" then
			-- ignore
		elseif xname == "jabber:iq:auth:0k:zerok" then
			-- ignore
		elseif xname == "jabber:iq:roster:query" then
			-- Roster
			local roster = {};
			local subscription_types = { from = true, to = true, both = true, none = true };
			for _,item_element in ipairs(tag.tags) do
				assert(item_element.name == "item");
				assert(item_element.attr.jid);
				assert(subscription_types[item_element.attr.subscription]);
				assert((item_element.attr.ask or "subscribe") == "subscribe")
				if item_element.name == "item" then
					local groups = {};
					for _,group_element in ipairs(item_element.tags) do
						assert(group_element.name == "group");
						groups[group_element:get_text()] = true;
					end
					local item = {
						name = item_element.attr.name;
						subscription = item_element.attr.subscription;
						ask = item_element.attr.ask;
						groups = groups;
					};
					roster[item_element.attr.jid] = item;
				end
			end
			stores.roster = roster;
		elseif xname == "jabber:iq:last:query" then
			-- Last activity
		elseif xname == "jabber:x:offline:foo" then
			-- Offline messages
		elseif xname == "vcard-temp:vCard" then
			-- vCards
			stores.vcard = st.preserialize(tag);
		else
			print("[warn] Unknown tag: "..xname);
		end
	end
	return userdata;
end

local function loop_over_users(path, host, cb)
	for file in lfs.dir(path) do
		if file:match("%.xml$") then
			local user = load_spool_file(host, file, path.."/"..file);
			if user then cb(user); end
		end
	end
end
local function loop_over_hosts(path, cb)
	for host in lfs.dir(path) do
		if host ~= "." and host ~= ".." and is_dir(path.."/"..host) then
			loop_over_users(path.."/"..host, host, cb);
		end
	end
end

local function reader(input)
	local path = clean_path(assert(input.path, "no input.path specified"));
	assert(is_dir(path), "input.path is not a directory");

	if input.host then
		return coroutine.wrap(function() loop_over_users(input.path, input.host, coroutine.yield) end);
	else
		return coroutine.wrap(function() loop_over_hosts(input.path, coroutine.yield) end);
	end
end

return {
	reader = reader;
};
