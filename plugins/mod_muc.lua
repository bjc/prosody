

local register_component = require "core.componentmanager".register_component;
local deregister_component = require "core.componentmanager".deregister_component;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local multitable_new = require "util.multitable".new;
local t_insert, t_remove = table.insert, table.remove;

if module:get_host_type() ~= "component" then
	error("MUC should be loaded as a component, please see http://prosody.im/doc/components", 0);
end

local muc_domain = module:get_host();
local muc_name = "MUCMUCMUC!!!";
local history_length = 20;

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
	-- history = {preserialized stanzas}
local rooms_info = multitable_new();

local persist_list = datamanager.load(nil, muc_domain, 'room_list') or {};
for room in pairs(persist_list) do
	rooms_info:set(room, datamanager.store(room, muc_domain, 'rooms') or nil);
end

local component;

function filter_xmlns_from_array(array, filters)
	local count = 0;
	for i=#array,1,-1 do
		local attr = array[i].attr;
		if filters[attr and attr.xmlns] then
			t_remove(array, i);
			count = count + 1;
		end
	end
	return count;
end
function filter_xmlns_from_stanza(stanza, filters)
	if filters then
		if filter_xmlns_from_array(stanza.tags, filters) ~= 0 then
			return stanza, filter_xmlns_from_array(stanza, filters);
		end
	end
	return stanza, 0;
end
local presence_filters = {["http://jabber.org/protocol/muc"]=true;["http://jabber.org/protocol/muc#user"]=true};
function get_filtered_presence(stanza)
	return filter_xmlns_from_stanza(st.deserialize(st.preserialize(stanza)), presence_filters);
end
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
	local msg = st.message({type='groupchat', from=current_nick})
		:tag('subject'):text(subject):up();
	broadcast_message_stanza(room, msg, false);
	--broadcast_message(current_nick, room, subject or "", nil);
	return true;
end

function broadcast_presence(type, from, room, code, newnick)
	local data = rooms:get(room, from);
	local stanza = st.presence({type=type, from=from})
		:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
		:tag("item", {affiliation=data.affiliation, role=data.role, nick = newnick}):up();
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
		if not subject and body then -- add to history
			local history = rooms_info:get(room, 'history');
			if not history then history = {}; rooms_info:set(room, 'history', history); end
			-- stanza = st.deserialize(st.preserialize(stanza));
			stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = muc_domain, stamp = datetime.datetime()}):up(); -- XEP-0203
			stanza:tag("x", {xmlns = "jabber:x:delay", from = muc_domain, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
			t_insert(history, st.preserialize(stanza));
			while #history > history_length do t_remove(history, 1) end
		end
	end
end
function broadcast_message_stanza(room, stanza, historic)
	local r = rooms:get(room);
	if r then
		for occupant, o_data in pairs(r) do
			for jid in pairs(o_data.sessions) do
				stanza.attr.to = jid;
				core_route_stanza(component, stanza);
			end
		end
		if historic then -- add to history
			local history = rooms_info:get(room, 'history');
			if not history then history = {}; rooms_info:set(room, 'history', history); end
			-- stanza = st.deserialize(st.preserialize(stanza));
			stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = muc_domain, stamp = datetime.datetime()}):up(); -- XEP-0203
			stanza:tag("x", {xmlns = "jabber:x:delay", from = muc_domain, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
			t_insert(history, st.preserialize(stanza));
			while #history > history_length do t_remove(history, 1) end
		end
	end
end
function broadcast_presence_stanza(room, stanza, code, nick)
	stanza = get_filtered_presence(stanza);
	local data = rooms:get(room, stanza.attr.from);
	stanza:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
		:tag("item", {affiliation=data.affiliation, role=data.role, nick=nick}):up();
	if code then
		stanza:tag("status", {code=code}):up();
	end
	local me;
	local r = rooms:get(room);
	if r then
		for occupant, o_data in pairs(r) do
			if occupant ~= stanza.attr.from then
				for jid in pairs(o_data.sessions) do
					stanza.attr.to = jid;
					core_route_stanza(component, stanza);
				end
			else
				me = o_data;
			end
		end
	end
	if me then
		stanza:tag("status", {code='110'});
		for jid in pairs(me.sessions) do
			stanza.attr.to = jid;
			core_route_stanza(component, stanza);
		end
	end
end

function handle_to_occupant(origin, stanza) -- PM, vCards, etc
	local from, to = stanza.attr.from, stanza.attr.to;
	local room = jid_bare(to);
	local current_nick = jid_nick:get(from, room);
	local type = stanza.attr.type;
	log("debug", "room: %s, current_nick: %s, stanza: %s", room or "nil", current_nick or "nil", stanza:top_tag());
	if stanza.name == "presence" then
		local pr = get_filtered_presence(stanza);
		pr.attr.from = to;
		if type == "error" then -- error, kick em out!
			if current_nick then
				log("debug", "kicking %s from %s", current_nick, room);
				local data = rooms:get(room, current_nick);
				data.role = 'none';
				local pr = st.presence({type='unavailable', from=current_nick}):tag('status'):text('This participant is kicked from the room because he sent an error presence'):up()
					--:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
					--:tag("item", {affiliation=data.affiliation, role=data.role}):up();
				broadcast_presence_stanza(room, pr);
				--broadcast_presence('unavailable', current_nick, room); -- TODO also add <status>This participant is kicked from the room because he sent an error presence: badformed error stanza</status>
				rooms:remove(room, current_nick);
				jid_nick:remove(from, room);
			end
		elseif type == "unavailable" then -- unavailable
			if current_nick then
				log("debug", "%s leaving %s", current_nick, room);
				local data = rooms:get(room, current_nick);
				data.role = 'none';
				broadcast_presence_stanza(room, pr);
				--broadcast_presence('unavailable', current_nick, room);
				rooms:remove(room, current_nick);
				jid_nick:remove(from, room);
			end
		elseif not type then -- available
			if current_nick then
				if current_nick == to then -- simple presence
					if #pr == #stanza then
						log("debug", "%s broadcasted presence", current_nick);
						broadcast_presence_stanza(room, pr);
					else -- possible rejoin
						log("debug", "%s had connection replaced", current_nick);
						local pr_ = st.presence({type='unavailable', from=from, to=current_nick}):tag('status'):text('Replaced by new connection');
						handle_to_occupant(origin, pr_); -- send unavailable
						handle_to_occupant(origin, pr); -- resend available
					end
				else -- change nick
					if rooms:get(room, to) then
						log("debug", "%s couldn't change nick", current_nick);
						origin.send(st.error_reply(stanza, "cancel", "conflict"));
					else
						local data = rooms:get(room, current_nick);
						local to_nick = select(3, jid_split(to));
						if to_nick then
							log("debug", "%s changing nick to %s", current_nick, to_nick);
							local p = st.presence({type='unavailable', from=current_nick});
								--[[:tag('x', {xmlns='http://jabber.org/protocol/muc#user'})
									:tag('item', {affiliation=data.affiliation, role=data.role, nick=to_nick}):up()
									:tag('status', {code='303'});]]
							broadcast_presence_stanza(room, p, '303', to_nick);
							--broadcast_presence('unavailable', current_nick, room, '303', to_nick);
							rooms:remove(room, current_nick);
							rooms:set(room, to, data);
							jid_nick:set(from, room, to);
							broadcast_presence_stanza(room, pr);
							--broadcast_presence(nil, to, room, nil);
						else
							--TODO malformed-jid
						end
					end
				end
			else -- enter room
				local new_nick = to;
				if rooms:get(room, to) then
					new_nick = nil;
				end
				if not new_nick then
					log("debug", "%s couldn't join due to nick conflict: %s", from, to);
					origin.send(st.error_reply(stanza, "cancel", "conflict"));
				else
					log("debug", "%s joining as %s", from, to);
					local data;
					if not rooms:get(room) and not rooms_info:get(room) then -- new room
						data = {affiliation='owner', role='moderator', jid=from, sessions={[from]=get_filtered_presence(stanza)}};
					end
					if not data then -- new occupant
						data = {affiliation='none', role='participant', jid=from, sessions={[from]=get_filtered_presence(stanza)}};
					end
					rooms:set(room, to, data);
					jid_nick:set(from, room, to);
					local r = rooms:get(room);
					if r then
						for occupant, o_data in pairs(r) do
							if occupant ~= to then
								local pres = get_filtered_presence(o_data.sessions[o_data.jid]);
								pres.attr.to, pres.attr.from = from, occupant;
								pres
								--local pres = st.presence({to=from, from=occupant})
									:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
									:tag("item", {affiliation=o_data.affiliation, role=o_data.role}):up();
								core_route_stanza(component, pres);
							end
						end
					end
					broadcast_presence_stanza(room, pr);
					--broadcast_presence(nil, to, room);
					local history = rooms_info:get(room, 'history'); -- send discussion history
					if history then
						for _, msg in ipairs(history) do
							msg = st.deserialize(msg);
							msg.attr.to=from;
							core_route_stanza(component, msg);
						end
					end
					if rooms_info:get(room, 'subject') then
						core_route_stanza(component, st.message({type='groupchat', from=room, to=from}):tag("subject"):text(rooms_info:get(room, 'subject')));
					end
				end
			end
		elseif type ~= 'result' then -- bad type
			origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
		end
	elseif not current_nick then -- not in room
		origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
	elseif stanza.name == "message" and type == "groupchat" then -- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	elseif stanza.name == "message" and type == "error" then
		if current_nick then
			log("debug", "%s kicked from %s for sending an error message", current_nick, room);
			local data = rooms:get(room, to);
			data.role = 'none';
			local pr = st.presence({type='unavailable', from=current_nick}):tag('status'):text('This participant is kicked from the room because he sent an error message to another occupant'):up()
				:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
				:tag("item", {affiliation=data.affiliation, role=data.role}):up();
			broadcast_presence_stanza(room, pr);
			rooms:remove(room, to);
			jid_nick:remove(from, room);
		end
	else -- private stanza
		local o_data = rooms:get(room, to);
		if o_data then
			log("debug", "%s sent private stanza to %s (%s)", from, to, o_data.jid);
			local jid = o_data.jid;
			if stanza.name=='iq' and type=='get' and stanza.tags[1].attr.xmlns == 'vcard-temp' then jid = jid_bare(jid); end
			stanza.attr.to, stanza.attr.from = jid, current_nick;
			core_route_stanza(component, stanza);
		else -- recipient not in room
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
		end
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
			local from = stanza.attr.from;
			stanza.attr.from = current_nick;
			local subject = getText(stanza, {"subject"});
			if subject then
				set_subject(current_nick, room, subject); -- TODO use broadcast_message_stanza
			else
				--broadcast_message(current_nick, room, nil, getText(stanza, {"body"}));
				broadcast_message_stanza(room, stanza, true);
			end
		end
	elseif stanza.name == "presence" then -- hack - some buggy clients send presence updates to the room rather than their nick
		local to = stanza.attr.to;
		local current_nick = jid_nick:get(stanza.attr.from, to);
		if current_nick then
			stanza.attr.to = current_nick;
			handle_to_occupant(origin, stanza);
			stanza.attr.to = to;
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
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

register_component(muc_domain, function(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	if to_resource and not to_node then
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
end);

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
