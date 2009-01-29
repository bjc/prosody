

local register_component = require "core.componentmanager".register_component;
local deregister_component = require "core.componentmanager".deregister_component;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local multitable_new = require "util.multitable".new;

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see http://prosody.im/doc/components", 0);
end

local muc_domain = module:get_host();

local muc_name = "MUCMUCMUC!!!";

-- room_name -> room
	-- occupant_room_nick -> data
		-- affiliation = ...
		-- role
		-- jid = occupant's real jid
local rooms = multitable_new();

local jid_nick = multitable_new(); -- real jid -> room's jid -> room nick

-- room_name -> info
	-- name - the room's friendly name
	-- subject - the room's subject
	-- non-anonymous = true|nil
	-- persistent = true|nil
local rooms_info = multitable_new();

local persist_list = datamanager.load(nil, muc_domain, 'room_list') or {};
for room in pairs(persist_list) do
	rooms_info:set(room, datamanager.store(room, muc_domain, 'rooms') or nil);
end

local component;

function getUsingPath(stanza, path, getText)
	local tag = stanza;
	for _, name in ipairs(path) do
		if type(tag) ~= 'table' then return; end
		tag = tag:child_with_name(name);
	end
	if tag and getText then tag = table.concat(tag); end
	return tag;
end
function getTag(stanza, path) return getUsingPath(stanza, path); end
function getText(stanza, path) return getUsingPath(stanza, path, true); end

function get_disco_info(stanza)
	return st.iq({type='result', id=stanza.attr.id, from=muc_domain, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='conference', type='text', name=muc_name}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}); -- TODO cache disco reply
end
function get_disco_items(stanza)
	local reply = st.iq({type='result', id=stanza.attr.id, from=muc_domain, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#items");
	for room in pairs(rooms_info:get()) do
		reply:tag("item", {jid=room, name=rooms_info:get(room, "name")}):up();
	end
	return reply; -- TODO cache disco reply
end
function get_room_disco_info(stanza)
	return st.iq({type='result', id=stanza.attr.id, from=stanza.attr.to, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='conference', type='text', name=rooms_info:get(stanza.attr.to, "name")}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}); -- TODO cache disco reply
end
function get_room_disco_items(stanza)
	return st.iq({type='result', id=stanza.attr.id, from=stanza.attr.to, to=stanza.attr.from}):query("http://jabber.org/protocol/disco#items");
end -- TODO allow non-private rooms

function save_room(room)
	local persistent = rooms_info:get(room, 'persistent');
	if persistent then
		datamanager.store(room, muc_domain, 'rooms', rooms_info:get(room));
	end
	if persistent ~= persist_list[room] then
		if not persistent then
			datamanager.store(room, muc_domain, 'rooms', nil);
		end
		persist_list[room] = persistent;
		datamanager.store(nil, muc_domain, 'room_list', persist_list);
	end
end

function set_subject(current_nick, room, subject)
	-- TODO check nick's authority
	if subject == "" then subject = nil; end
	rooms_info:set(room, 'subject', subject);
	save_room();
	broadcast_message(current_nick, room, subject or "", nil);
	return true;
end

function broadcast_presence(type, from, room, code)
	local data = rooms:get(room, from);
	local stanza = st.presence({type=type, from=from})
		:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
		:tag("item", {affiliation=data.affiliation, role=data.role}):up();
	if code then
		stanza:tag("status", {code=code}):up();
	end
	local me;
	local r = rooms:get(room);
	if r then
		for occupant, o_data in pairs(r) do
			if occupant ~= from then
				stanza.attr.to = o_data.jid;
				core_route_stanza(component, stanza);
			else
				me = o_data.jid;
			end
		end
	end
	if me then
		stanza:tag("status", {code='110'});
		stanza.attr.to = me;
		core_route_stanza(component, stanza);
	end
end
function broadcast_message(from, room, subject, body)
	local stanza = st.message({type='groupchat', from=from});
	if subject then stanza:tag('subject'):text(subject):up(); end
	if body then stanza:tag('body'):text(body):up(); end
	local r = rooms:get(room);
	if r then
		for occupant, o_data in pairs(r) do
			stanza.attr.to = o_data.jid;
			core_route_stanza(component, stanza);
		end
	end
end

function handle_to_occupant(origin, stanza) -- PM, vCards, etc
	local from, to = stanza.attr.from, stanza.attr.to;
	local room = jid_bare(to);
	local current_nick = jid_nick:get(from, room);
	local type = stanza.attr.type;
	if stanza.name == "presence" then
		if type == "error" then -- error, kick em out!
			local data = rooms:get(room, to);
			data.role = 'none';
			broadcast_presence('unavailable', to, room); -- TODO also add <status>This participant is kicked from the room because he sent an error presence: badformed error stanza</status>
			rooms:remove(room, to);
			jid_nick:remove(from, room);
		elseif type == "unavailable" then -- unavailable
			if current_nick == to then
				local data = rooms:get(room, to);
				data.role = 'none';
				broadcast_presence('unavailable', to, room);
				rooms:remove(room, to);
				jid_nick:remove(from, room);
			end -- TODO else do nothing?
		elseif not type then -- available
			if current_nick then
				if current_nick == to then -- simple presence
					-- TODO broadcast
				else -- change nick
					if rooms:get(room, to) then
						origin.send(st.error_reply(stanza, "cancel", "conflict"));
					else
						local data = rooms:get(room, current_nick);
						broadcast_presence('unavailable', current_nick, room, '303');
						rooms:remove(room, current_nick);
						rooms:set(room, to, data);
						jid_nick:set(from, room, to);
						broadcast_presence(nil, to, room);
					end
				end
			else -- enter room
				if rooms:get(room, to) then
					origin.send(st.error_reply(stanza, "cancel", "conflict"));
				else
					local data;
					if not rooms:get(room) and not rooms_info:get(room) then -- new room
						data = {affiliation='owner', role='moderator', jid=from};
					end
					if not data then -- new occupant
						data = {affiliation='none', role='participant', jid=from};
					end
					rooms:set(room, to, data);
					jid_nick:set(from, room, to);
					local r = rooms:get(room);
					if r then
						for occupant, o_data in pairs(r) do
							if occupant ~= from then
								local pres = st.presence({to=from, from=occupant})
									:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
									:tag("item", {affiliation=o_data.affiliation, role=o_data.role}):up();
								core_route_stanza(component, pres);
							end
						end
					end
					broadcast_presence(nil, to, room);
					-- TODO send discussion history
					if rooms_info:get(room, 'subject') then
						core_route_stanza(component, st.message({type='groupchat', from=room, to=from}):tag("subject"):text(rooms_info:get(room, 'subject')));
					end
				end
			end
		elseif type ~= 'result' then -- bad type
			origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
		end
	elseif stanza.name == "message" and type == "groupchat" then
		-- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	else
		origin.send(st.error_reply(stanza, "cancel", "not-implemented", "Private stanzas not implemented")); -- TODO route private stanza
	end
end

function handle_to_room(origin, stanza) -- presence changes and groupchat messages, along with disco/etc
	local type = stanza.attr.type;
	if stanza.name == "iq" and type == "get" then -- disco requests
		local xmlns = stanza.tags[1].attr.xmlns;
		if xmlns == "http://jabber.org/protocol/disco#info" then
			origin.send(get_room_disco_info(stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" then
			origin.send(get_room_disco_items(stanza));
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then
		local from, to = stanza.attr.from, stanza.attr.to;
		local room = jid_bare(to);
		local current_nick = jid_nick:get(from, room);
		if not current_nick then -- not in room
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		else
			local subject = getText(stanza, {"subject"});
			if subject then
				set_subject(current_nick, room, subject);
			else
				broadcast_message(current_nick, room, nil, getText(stanza, {"body"}));
				-- TODO add to discussion history
			end
		end
	else
		if type == "error" or type == "result" then return; end
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end
end

function handle_to_domain(origin, stanza)
	local type = stanza.attr.type;
	if type == "error" or type == "result" then return; end
	if stanza.name == "iq" and type == "get" then
		local xmlns = stanza.tags[1].attr.xmlns;
		if xmlns == "http://jabber.org/protocol/disco#info" then
			origin.send(get_disco_info(stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" then
			origin.send(get_disco_items(stanza));
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- TODO disco/etc
		end
	else
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "The muc server doesn't deal with messages and presence directed at it"));
	end
end

function handle_stanza(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	if stanza.name == "presence" and stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
		if type == "error" or type == "result" then return; end
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- FIXME what's appropriate?
	elseif to_resource and not to_node then
		if type == "error" or type == "result" then return; end
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); -- host/resource
	elseif to_resource then
		handle_to_occupant(origin, stanza);
	elseif to_node then
		handle_to_room(origin, stanza)
	else -- to the main muc domain
		if type == "error" or type == "result" then return; end
		handle_to_domain(origin, stanza);
	end
end

module.load_component = function()
	return handle_stanza; -- Return the function that we want to handle incoming stanzas
end

module.unload = function()
	deregister_component(muc_domain);
end
module.save = function()
	return {rooms = rooms.data; jid_nick = jid_nick.data; rooms_info = rooms_info.data; persist_list = persist_list};
end
module.restore = function(data)
	rooms.data, jid_nick.data, rooms_info.data, persist_list =
	data.rooms or {}, data.jid_nick or {}, data.rooms_info or {}, data.persist_list or {};
end
