-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local select = select;
local pairs, ipairs = pairs, ipairs;

local datetime = require "util.datetime";

local dataform = require "util.dataforms";

local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local t_insert, t_remove = table.insert, table.remove;
local setmetatable = setmetatable;
local base64 = require "util.encodings".base64;
local md5 = require "util.hashes".md5;

local muc_domain = nil; --module:get_host();
local default_history_length, max_history_length = 20, math.huge;

------------
local function filter_xmlns_from_array(array, filters)
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
local function filter_xmlns_from_stanza(stanza, filters)
	if filters then
		if filter_xmlns_from_array(stanza.tags, filters) ~= 0 then
			return stanza, filter_xmlns_from_array(stanza, filters);
		end
	end
	return stanza, 0;
end
local presence_filters = {["http://jabber.org/protocol/muc"]=true;["http://jabber.org/protocol/muc#user"]=true};
local function get_filtered_presence(stanza)
	return filter_xmlns_from_stanza(st.clone(stanza):reset(), presence_filters);
end
local kickable_error_conditions = {
	["gone"] = true;
	["internal-server-error"] = true;
	["item-not-found"] = true;
	["jid-malformed"] = true;
	["recipient-unavailable"] = true;
	["redirect"] = true;
	["remote-server-not-found"] = true;
	["remote-server-timeout"] = true;
	["service-unavailable"] = true;
	["malformed error"] = true;
};

local function get_error_condition(stanza)
	local _, condition = stanza:get_error();
	return condition or "malformed error";
end

local function is_kickable_error(stanza)
	local cond = get_error_condition(stanza);
	return kickable_error_conditions[cond] and cond;
end
local function getUsingPath(stanza, path, getText)
	local tag = stanza;
	for _, name in ipairs(path) do
		if type(tag) ~= 'table' then return; end
		tag = tag:child_with_name(name);
	end
	if tag and getText then tag = table.concat(tag); end
	return tag;
end
local function getTag(stanza, path) return getUsingPath(stanza, path); end
local function getText(stanza, path) return getUsingPath(stanza, path, true); end
-----------

local room_mt = {};
room_mt.__index = room_mt;

function room_mt:__tostring()
	return "MUC room ("..self.jid..")";
end

function room_mt:get_default_role(affiliation)
	if affiliation == "owner" or affiliation == "admin" then
		return "moderator";
	elseif affiliation == "member" then
		return "participant";
	elseif not affiliation then
		if not self:is_members_only() then
			return self:is_moderated() and "visitor" or "participant";
		end
	end
end

function room_mt:broadcast_presence(stanza, sid, code, nick)
	stanza = get_filtered_presence(stanza);
	local occupant = self._occupants[stanza.attr.from];
	stanza:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
		:tag("item", {affiliation=occupant.affiliation or "none", role=occupant.role or "none", nick=nick}):up();
	if code then
		stanza:tag("status", {code=code}):up();
	end
	self:broadcast_except_nick(stanza, stanza.attr.from);
	local me = self._occupants[stanza.attr.from];
	if me then
		stanza:tag("status", {code='110'}):up();
		stanza.attr.to = sid;
		self:_route_stanza(stanza);
	end
end
function room_mt:broadcast_message(stanza, historic)
	local to = stanza.attr.to;
	for occupant, o_data in pairs(self._occupants) do
		for jid in pairs(o_data.sessions) do
			stanza.attr.to = jid;
			self:_route_stanza(stanza);
		end
	end
	stanza.attr.to = to;
	if historic then -- add to history
		local history = self._data['history'];
		if not history then history = {}; self._data['history'] = history; end
		stanza = st.clone(stanza);
		stanza.attr.to = "";
		local stamp = datetime.datetime();
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = muc_domain, stamp = stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = muc_domain, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
		local entry = { stanza = stanza, stamp = stamp };
		t_insert(history, entry);
		while #history > (self._data.history_length or default_history_length) do t_remove(history, 1) end
	end
end
function room_mt:broadcast_except_nick(stanza, nick)
	for rnick, occupant in pairs(self._occupants) do
		if rnick ~= nick then
			for jid in pairs(occupant.sessions) do
				stanza.attr.to = jid;
				self:_route_stanza(stanza);
			end
		end
	end
end

function room_mt:send_occupant_list(to)
	local current_nick = self._jid_nick[to];
	for occupant, o_data in pairs(self._occupants) do
		if occupant ~= current_nick then
			local pres = get_filtered_presence(o_data.sessions[o_data.jid]);
			pres.attr.to, pres.attr.from = to, occupant;
			pres:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
				:tag("item", {affiliation=o_data.affiliation or "none", role=o_data.role or "none"}):up();
			self:_route_stanza(pres);
		end
	end
end
function room_mt:send_history(to, stanza)
	local history = self._data['history']; -- send discussion history
	if history then
		local x_tag = stanza and stanza:get_child("x", "http://jabber.org/protocol/muc");
		local history_tag = x_tag and x_tag:get_child("history", "http://jabber.org/protocol/muc");
		
		local maxchars = history_tag and tonumber(history_tag.attr.maxchars);
		if maxchars then maxchars = math.floor(maxchars); end
		
		local maxstanzas = math.floor(history_tag and tonumber(history_tag.attr.maxstanzas) or #history);
		if not history_tag then maxstanzas = 20; end

		local seconds = history_tag and tonumber(history_tag.attr.seconds);
		if seconds then seconds = datetime.datetime(os.time() - math.floor(seconds)); end

		local since = history_tag and history_tag.attr.since;
		if since then since = datetime.parse(since); since = since and datetime.datetime(since); end
		if seconds and (not since or since < seconds) then since = seconds; end

		local n = 0;
		local charcount = 0;
		
		for i=#history,1,-1 do
			local entry = history[i];
			if maxchars then
				if not entry.chars then
					entry.stanza.attr.to = "";
					entry.chars = #tostring(entry.stanza);
				end
				charcount = charcount + entry.chars + #to;
				if charcount > maxchars then break; end
			end
			if since and since > entry.stamp then break; end
			if n + 1 > maxstanzas then break; end
			n = n + 1;
		end
		for i=#history-n+1,#history do
			local msg = history[i].stanza;
			msg.attr.to = to;
			self:_route_stanza(msg);
		end
	end
	if self._data['subject'] then
		self:_route_stanza(st.message({type='groupchat', from=self._data['subject_from'] or self.jid, to=to}):tag("subject"):text(self._data['subject']));
	end
end

function room_mt:get_disco_info(stanza)
	local count = 0; for _ in pairs(self._occupants) do count = count + 1; end
	return st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category="conference", type="text", name=self:get_name()}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}):up()
		:tag("feature", {var=self:get_password() and "muc_passwordprotected" or "muc_unsecured"}):up()
		:tag("feature", {var=self:is_moderated() and "muc_moderated" or "muc_unmoderated"}):up()
		:tag("feature", {var=self:is_members_only() and "muc_membersonly" or "muc_open"}):up()
		:tag("feature", {var=self:is_persistent() and "muc_persistent" or "muc_temporary"}):up()
		:tag("feature", {var=self:is_hidden() and "muc_hidden" or "muc_public"}):up()
		:tag("feature", {var=self._data.whois ~= "anyone" and "muc_semianonymous" or "muc_nonanonymous"}):up()
		:add_child(dataform.new({
			{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/muc#roominfo" },
			{ name = "muc#roominfo_description", label = "Description", value = "" },
			{ name = "muc#roominfo_occupants", label = "Number of occupants", value = tostring(count) }
		}):form({["muc#roominfo_description"] = self:get_description()}, 'result'))
	;
end
function room_mt:get_disco_items(stanza)
	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for room_jid in pairs(self._occupants) do
		reply:tag("item", {jid = room_jid, name = room_jid:match("/(.*)")}):up();
	end
	return reply;
end
function room_mt:set_subject(current_nick, subject)
	-- TODO check nick's authority
	if subject == "" then subject = nil; end
	self._data['subject'] = subject;
	self._data['subject_from'] = current_nick;
	if self.save then self:save(); end
	local msg = st.message({type='groupchat', from=current_nick})
		:tag('subject'):text(subject):up();
	self:broadcast_message(msg, false);
	return true;
end

local function build_unavailable_presence_from_error(stanza)
	local type, condition, text = stanza:get_error();
	local error_message = "Kicked: "..(condition and condition:gsub("%-", " ") or "presence error");
	if text then
		error_message = error_message..": "..text;
	end
	return st.presence({type='unavailable', from=stanza.attr.from, to=stanza.attr.to})
		:tag('status'):text(error_message);
end

function room_mt:set_name(name)
	if name == "" or type(name) ~= "string" or name == (jid_split(self.jid)) then name = nil; end
	if self._data.name ~= name then
		self._data.name = name;
		if self.save then self:save(true); end
	end
end
function room_mt:get_name()
	return self._data.name or jid_split(self.jid);
end
function room_mt:set_description(description)
	if description == "" or type(description) ~= "string" then description = nil; end
	if self._data.description ~= description then
		self._data.description = description;
		if self.save then self:save(true); end
	end
end
function room_mt:get_description()
	return self._data.description;
end
function room_mt:set_password(password)
	if password == "" or type(password) ~= "string" then password = nil; end
	if self._data.password ~= password then
		self._data.password = password;
		if self.save then self:save(true); end
	end
end
function room_mt:get_password()
	return self._data.password;
end
function room_mt:set_moderated(moderated)
	moderated = moderated and true or nil;
	if self._data.moderated ~= moderated then
		self._data.moderated = moderated;
		if self.save then self:save(true); end
	end
end
function room_mt:is_moderated()
	return self._data.moderated;
end
function room_mt:set_members_only(members_only)
	members_only = members_only and true or nil;
	if self._data.members_only ~= members_only then
		self._data.members_only = members_only;
		if self.save then self:save(true); end
	end
end
function room_mt:is_members_only()
	return self._data.members_only;
end
function room_mt:set_persistent(persistent)
	persistent = persistent and true or nil;
	if self._data.persistent ~= persistent then
		self._data.persistent = persistent;
		if self.save then self:save(true); end
	end
end
function room_mt:is_persistent()
	return self._data.persistent;
end
function room_mt:set_hidden(hidden)
	hidden = hidden and true or nil;
	if self._data.hidden ~= hidden then
		self._data.hidden = hidden;
		if self.save then self:save(true); end
	end
end
function room_mt:is_hidden()
	return self._data.hidden;
end
function room_mt:set_changesubject(changesubject)
	changesubject = changesubject and true or nil;
	if self._data.changesubject ~= changesubject then
		self._data.changesubject = changesubject;
		if self.save then self:save(true); end
	end
end
function room_mt:get_changesubject()
	return self._data.changesubject;
end
function room_mt:get_historylength()
	return self._data.history_length or default_history_length;
end
function room_mt:set_historylength(length)
	length = math.min(tonumber(length) or default_history_length, max_history_length or math.huge);
	if length == default_history_length then
		length = nil;
	end
	self._data.history_length = length;
end


local function construct_stanza_id(room, stanza)
	local from_jid, to_nick = stanza.attr.from, stanza.attr.to;
	local from_nick = room._jid_nick[from_jid];
	local occupant = room._occupants[to_nick];
	local to_jid = occupant.jid;
	
	return from_nick, to_jid, base64.encode(to_jid.."\0"..stanza.attr.id.."\0"..md5(from_jid));
end
local function deconstruct_stanza_id(room, stanza)
	local from_jid_possiblybare, to_nick = stanza.attr.from, stanza.attr.to;
	local from_jid, id, to_jid_hash = (base64.decode(stanza.attr.id) or ""):match("^(.+)%z(.*)%z(.+)$");
	local from_nick = room._jid_nick[from_jid];

	if not(from_nick) then return; end
	if not(from_jid_possiblybare == from_jid or from_jid_possiblybare == jid_bare(from_jid)) then return; end

	local occupant = room._occupants[to_nick];
	for to_jid in pairs(occupant and occupant.sessions or {}) do
		if md5(to_jid) == to_jid_hash then
			return from_nick, to_jid, id;
		end
	end
end


function room_mt:handle_to_occupant(origin, stanza) -- PM, vCards, etc
	local from, to = stanza.attr.from, stanza.attr.to;
	local room = jid_bare(to);
	local current_nick = self._jid_nick[from];
	local type = stanza.attr.type;
	log("debug", "room: %s, current_nick: %s, stanza: %s", room or "nil", current_nick or "nil", stanza:top_tag());
	if (select(2, jid_split(from)) == muc_domain) then error("Presence from the MUC itself!!!"); end
	if stanza.name == "presence" then
		local pr = get_filtered_presence(stanza);
		pr.attr.from = current_nick;
		if type == "error" then -- error, kick em out!
			if current_nick then
				log("debug", "kicking %s from %s", current_nick, room);
				self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza));
			end
		elseif type == "unavailable" then -- unavailable
			if current_nick then
				log("debug", "%s leaving %s", current_nick, room);
				self._jid_nick[from] = nil;
				local occupant = self._occupants[current_nick];
				local new_jid = next(occupant.sessions);
				if new_jid == from then new_jid = next(occupant.sessions, new_jid); end
				if new_jid then
					local jid = occupant.jid;
					occupant.jid = new_jid;
					occupant.sessions[from] = nil;
					pr.attr.to = from;
					pr:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
						:tag("item", {affiliation=occupant.affiliation or "none", role='none'}):up()
						:tag("status", {code='110'}):up();
					self:_route_stanza(pr);
					if jid ~= new_jid then
						pr = st.clone(occupant.sessions[new_jid])
							:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
							:tag("item", {affiliation=occupant.affiliation or "none", role=occupant.role or "none"});
						pr.attr.from = current_nick;
						self:broadcast_except_nick(pr, current_nick);
					end
				else
					occupant.role = 'none';
					self:broadcast_presence(pr, from);
					self._occupants[current_nick] = nil;
				end
			end
		elseif not type then -- available
			if current_nick then
				--if #pr == #stanza or current_nick ~= to then -- commented because google keeps resending directed presence
					if current_nick == to then -- simple presence
						log("debug", "%s broadcasted presence", current_nick);
						self._occupants[current_nick].sessions[from] = pr;
						self:broadcast_presence(pr, from);
					else -- change nick
						local occupant = self._occupants[current_nick];
						local is_multisession = next(occupant.sessions, next(occupant.sessions));
						if self._occupants[to] or is_multisession then
							log("debug", "%s couldn't change nick", current_nick);
							local reply = st.error_reply(stanza, "cancel", "conflict"):up();
							reply.tags[1].attr.code = "409";
							origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
						else
							local data = self._occupants[current_nick];
							local to_nick = select(3, jid_split(to));
							if to_nick then
								log("debug", "%s (%s) changing nick to %s", current_nick, data.jid, to);
								local p = st.presence({type='unavailable', from=current_nick});
								self:broadcast_presence(p, from, '303', to_nick);
								self._occupants[current_nick] = nil;
								self._occupants[to] = data;
								self._jid_nick[from] = to;
								pr.attr.from = to;
								self._occupants[to].sessions[from] = pr;
								self:broadcast_presence(pr, from);
							else
								--TODO malformed-jid
							end
						end
					end
				--else -- possible rejoin
				--	log("debug", "%s had connection replaced", current_nick);
				--	self:handle_to_occupant(origin, st.presence({type='unavailable', from=from, to=to})
				--		:tag('status'):text('Replaced by new connection'):up()); -- send unavailable
				--	self:handle_to_occupant(origin, stanza); -- resend available
				--end
			else -- enter room
				local new_nick = to;
				local is_merge;
				if self._occupants[to] then
					if jid_bare(from) ~= jid_bare(self._occupants[to].jid) then
						new_nick = nil;
					end
					is_merge = true;
				end
				local password = stanza:get_child("x", "http://jabber.org/protocol/muc");
				password = password and password:get_child("password", "http://jabber.org/protocol/muc");
				password = password and password[1] ~= "" and password[1];
				if self:get_password() and self:get_password() ~= password then
					log("debug", "%s couldn't join due to invalid password: %s", from, to);
					local reply = st.error_reply(stanza, "auth", "not-authorized"):up();
					reply.tags[1].attr.code = "401";
					origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				elseif not new_nick then
					log("debug", "%s couldn't join due to nick conflict: %s", from, to);
					local reply = st.error_reply(stanza, "cancel", "conflict"):up();
					reply.tags[1].attr.code = "409";
					origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				else
					log("debug", "%s joining as %s", from, to);
					if not next(self._affiliations) then -- new room, no owners
						self._affiliations[jid_bare(from)] = "owner";
					end
					local affiliation = self:get_affiliation(from);
					local role = self:get_default_role(affiliation)
					if role then -- new occupant
						if not is_merge then
							self._occupants[to] = {affiliation=affiliation, role=role, jid=from, sessions={[from]=get_filtered_presence(stanza)}};
						else
							self._occupants[to].sessions[from] = get_filtered_presence(stanza);
						end
						self._jid_nick[from] = to;
						self:send_occupant_list(from);
						pr.attr.from = to;
						pr:tag("x", {xmlns='http://jabber.org/protocol/muc#user'})
							:tag("item", {affiliation=affiliation or "none", role=role or "none"}):up();
						if not is_merge then
							self:broadcast_except_nick(pr, to);
						end
						pr:tag("status", {code='110'}):up();
						if self._data.whois == 'anyone' then
							pr:tag("status", {code='100'}):up();
						end
						pr.attr.to = from;
						self:_route_stanza(pr);
						self:send_history(from, stanza);
					elseif not affiliation then -- registration required for entering members-only room
						local reply = st.error_reply(stanza, "auth", "registration-required"):up();
						reply.tags[1].attr.code = "407";
						origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
					else -- banned
						local reply = st.error_reply(stanza, "auth", "forbidden"):up();
						reply.tags[1].attr.code = "403";
						origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
					end
				end
			end
		elseif type ~= 'result' then -- bad type
			if type ~= 'visible' and type ~= 'invisible' then -- COMPAT ejabberd can broadcast or forward XEP-0018 presences
				origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
			end
		end
	elseif not current_nick then -- not in room
		if (type == "error" or type == "result") and stanza.name == "iq" then
			local id = stanza.attr.id;
			stanza.attr.from, stanza.attr.to, stanza.attr.id = deconstruct_stanza_id(self, stanza);
			if stanza.attr.id then
				self:_route_stanza(stanza);
			end
			stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
		elseif type ~= "error" then
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then -- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	elseif current_nick and stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza)); -- send unavailable
	else -- private stanza
		local o_data = self._occupants[to];
		if o_data then
			log("debug", "%s sent private stanza to %s (%s)", from, to, o_data.jid);
			if stanza.name == "iq" then
				local id = stanza.attr.id;
				if stanza.attr.type == "get" or stanza.attr.type == "set" then
					stanza.attr.from, stanza.attr.to, stanza.attr.id = construct_stanza_id(self, stanza);
				else
					stanza.attr.from, stanza.attr.to, stanza.attr.id = deconstruct_stanza_id(self, stanza);
				end
				if type == 'get' and stanza.tags[1].attr.xmlns == 'vcard-temp' then
					stanza.attr.to = jid_bare(stanza.attr.to);
				end
				if stanza.attr.id then
					self:_route_stanza(stanza);
				end
				stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
			else -- message
				stanza.attr.from = current_nick;
				for jid in pairs(o_data.sessions) do
					stanza.attr.to = jid;
					self:_route_stanza(stanza);
				end
				stanza.attr.from, stanza.attr.to = from, to;
			end
		elseif type ~= "error" and type ~= "result" then -- recipient not in room
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
		end
	end
end

function room_mt:send_form(origin, stanza)
	origin.send(st.reply(stanza):query("http://jabber.org/protocol/muc#owner")
		:add_child(self:get_form_layout():form())
	);
end

function room_mt:get_form_layout()
	local form = dataform.new({
		title = "Configuration for "..self.jid,
		instructions = "Complete and submit this form to configure the room.",
		{
			name = 'FORM_TYPE',
			type = 'hidden',
			value = 'http://jabber.org/protocol/muc#roomconfig'
		},
		{
			name = 'muc#roomconfig_roomname',
			type = 'text-single',
			label = 'Name',
			value = self:get_name() or "",
		},
		{
			name = 'muc#roomconfig_roomdesc',
			type = 'text-single',
			label = 'Description',
			value = self:get_description() or "",
		},
		{
			name = 'muc#roomconfig_persistentroom',
			type = 'boolean',
			label = 'Make Room Persistent?',
			value = self:is_persistent()
		},
		{
			name = 'muc#roomconfig_publicroom',
			type = 'boolean',
			label = 'Make Room Publicly Searchable?',
			value = not self:is_hidden()
		},
		{
			name = 'muc#roomconfig_changesubject',
			type = 'boolean',
			label = 'Allow Occupants to Change Subject?',
			value = self:get_changesubject()
		},
		{
			name = 'muc#roomconfig_whois',
			type = 'list-single',
			label = 'Who May Discover Real JIDs?',
			value = {
				{ value = 'moderators', label = 'Moderators Only', default = self._data.whois == 'moderators' },
				{ value = 'anyone',     label = 'Anyone',          default = self._data.whois == 'anyone' }
			}
		},
		{
			name = 'muc#roomconfig_roomsecret',
			type = 'text-private',
			label = 'Password',
			value = self:get_password() or "",
		},
		{
			name = 'muc#roomconfig_moderatedroom',
			type = 'boolean',
			label = 'Make Room Moderated?',
			value = self:is_moderated()
		},
		{
			name = 'muc#roomconfig_membersonly',
			type = 'boolean',
			label = 'Make Room Members-Only?',
			value = self:is_members_only()
		},
		{
			name = 'muc#roomconfig_historylength',
			type = 'text-single',
			label = 'Maximum Number of History Messages Returned by Room',
			value = tostring(self:get_historylength())
		}
	});
	return module:fire_event("muc-config-form", { room = self, form = form }) or form;
end

local valid_whois = {
	moderators = true,
	anyone = true,
}

function room_mt:process_form(origin, stanza)
	local query = stanza.tags[1];
	local form;
	for _, tag in ipairs(query.tags) do if tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then form = tag; break; end end
	if not form then origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); return; end
	if form.attr.type == "cancel" then origin.send(st.reply(stanza)); return; end
	if form.attr.type ~= "submit" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Not a submitted form")); return; end

	local fields = self:get_form_layout():data(form);
	if fields.FORM_TYPE ~= "http://jabber.org/protocol/muc#roomconfig" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Form is not of type room configuration")); return; end

	local dirty = false

	local event = { room = self, fields = fields, changed = dirty };
	module:fire_event("muc-config-submitted", event);
	dirty = event.changed or dirty;

	local name = fields['muc#roomconfig_roomname'];
	if name ~= self:get_name() then
		self:set_name(name);
	end

	local description = fields['muc#roomconfig_roomdesc'];
	if description ~= self:get_description() then
		self:set_description(description);
	end

	local persistent = fields['muc#roomconfig_persistentroom'];
	dirty = dirty or (self:is_persistent() ~= persistent)
	module:log("debug", "persistent=%s", tostring(persistent));

	local moderated = fields['muc#roomconfig_moderatedroom'];
	dirty = dirty or (self:is_moderated() ~= moderated)
	module:log("debug", "moderated=%s", tostring(moderated));

	local membersonly = fields['muc#roomconfig_membersonly'];
	dirty = dirty or (self:is_members_only() ~= membersonly)
	module:log("debug", "membersonly=%s", tostring(membersonly));

	local public = fields['muc#roomconfig_publicroom'];
	dirty = dirty or (self:is_hidden() ~= (not public and true or nil))

	local changesubject = fields['muc#roomconfig_changesubject'];
	dirty = dirty or (self:get_changesubject() ~= (not changesubject and true or nil))
	module:log('debug', 'changesubject=%s', changesubject and "true" or "false")

	local historylength = tonumber(fields['muc#roomconfig_historylength']);
	dirty = dirty or (historylength and (self:get_historylength() ~= historylength));
	module:log('debug', 'historylength=%s', historylength)


	local whois = fields['muc#roomconfig_whois'];
	if not valid_whois[whois] then
	    origin.send(st.error_reply(stanza, 'cancel', 'bad-request', "Invalid value for 'whois'"));
	    return;
	end
	local whois_changed = self._data.whois ~= whois
	self._data.whois = whois
	module:log('debug', 'whois=%s', whois)

	local password = fields['muc#roomconfig_roomsecret'];
	if self:get_password() ~= password then
		self:set_password(password);
	end
	self:set_moderated(moderated);
	self:set_members_only(membersonly);
	self:set_persistent(persistent);
	self:set_hidden(not public);
	self:set_changesubject(changesubject);
	self:set_historylength(historylength);

	if self.save then self:save(true); end
	origin.send(st.reply(stanza));

	if dirty or whois_changed then
		local msg = st.message({type='groupchat', from=self.jid})
			:tag('x', {xmlns='http://jabber.org/protocol/muc#user'}):up()

		if dirty then
			msg.tags[1]:tag('status', {code = '104'}):up();
		end
		if whois_changed then
			local code = (whois == 'moderators') and "173" or "172";
			msg.tags[1]:tag('status', {code = code}):up();
		end

		self:broadcast_message(msg, false)
	end
end

function room_mt:destroy(newjid, reason, password)
	local pr = st.presence({type = "unavailable"})
		:tag("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", { affiliation='none', role='none' }):up()
			:tag("destroy", {jid=newjid})
	if reason then pr:tag("reason"):text(reason):up(); end
	if password then pr:tag("password"):text(password):up(); end
	for nick, occupant in pairs(self._occupants) do
		pr.attr.from = nick;
		for jid in pairs(occupant.sessions) do
			pr.attr.to = jid;
			self:_route_stanza(pr);
			self._jid_nick[jid] = nil;
		end
		self._occupants[nick] = nil;
	end
	self:set_persistent(false);
	module:fire_event("muc-room-destroyed", { room = self });
end

function room_mt:handle_to_room(origin, stanza) -- presence changes and groupchat messages, along with disco/etc
	local type = stanza.attr.type;
	local xmlns = stanza.tags[1] and stanza.tags[1].attr.xmlns;
	if stanza.name == "iq" then
		if xmlns == "http://jabber.org/protocol/disco#info" and type == "get" and not stanza.tags[1].attr.node then
			origin.send(self:get_disco_info(stanza));
		elseif xmlns == "http://jabber.org/protocol/disco#items" and type == "get" and not stanza.tags[1].attr.node then
			origin.send(self:get_disco_items(stanza));
		elseif xmlns == "http://jabber.org/protocol/muc#admin" then
			local actor = stanza.attr.from;
			local affiliation = self:get_affiliation(actor);
			local current_nick = self._jid_nick[actor];
			local role = current_nick and self._occupants[current_nick].role or self:get_default_role(affiliation);
			local item = stanza.tags[1].tags[1];
			if item and item.name == "item" then
				if type == "set" then
					local callback = function() origin.send(st.reply(stanza)); end
					if item.attr.jid then -- Validate provided JID
						item.attr.jid = jid_prep(item.attr.jid);
						if not item.attr.jid then
							origin.send(st.error_reply(stanza, "modify", "jid-malformed"));
							return;
						end
					end
					if not item.attr.jid and item.attr.nick then -- COMPAT Workaround for Miranda sending 'nick' instead of 'jid' when changing affiliation
						local occupant = self._occupants[self.jid.."/"..item.attr.nick];
						if occupant then item.attr.jid = occupant.jid; end
					elseif not item.attr.nick and item.attr.jid then
						local nick = self._jid_nick[item.attr.jid];
						if nick then item.attr.nick = select(3, jid_split(nick)); end
					end
					local reason = item.tags[1] and item.tags[1].name == "reason" and #item.tags[1] == 1 and item.tags[1][1];
					if item.attr.affiliation and item.attr.jid and not item.attr.role then
						local success, errtype, err = self:set_affiliation(actor, item.attr.jid, item.attr.affiliation, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					elseif item.attr.role and item.attr.nick and not item.attr.affiliation then
						local success, errtype, err = self:set_role(actor, self.jid.."/"..item.attr.nick, item.attr.role, callback, reason);
						if not success then origin.send(st.error_reply(stanza, errtype, err)); end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				elseif type == "get" then
					local _aff = item.attr.affiliation;
					local _rol = item.attr.role;
					if _aff and not _rol then
						if affiliation == "owner" or (affiliation == "admin" and _aff ~= "owner" and _aff ~= "admin") then
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for jid, affiliation in pairs(self._affiliations) do
								if affiliation == _aff then
									reply:tag("item", {affiliation = _aff, jid = jid}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					elseif _rol and not _aff then
						if role == "moderator" then
							-- TODO allow admins and owners not in room? Provide read-only access to everyone who can see the participants anyway?
							if _rol == "none" then _rol = nil; end
							local reply = st.reply(stanza):query("http://jabber.org/protocol/muc#admin");
							for occupant_jid, occupant in pairs(self._occupants) do
								if occupant.role == _rol then
									reply:tag("item", {
										nick = select(3, jid_split(occupant_jid)),
										role = _rol or "none",
										affiliation = occupant.affiliation or "none",
										jid = occupant.jid
										}):up();
								end
							end
							origin.send(reply);
						else
							origin.send(st.error_reply(stanza, "auth", "forbidden"));
						end
					else
						origin.send(st.error_reply(stanza, "cancel", "bad-request"));
					end
				end
			elseif type == "set" or type == "get" then
				origin.send(st.error_reply(stanza, "cancel", "bad-request"));
			end
		elseif xmlns == "http://jabber.org/protocol/muc#owner" and (type == "get" or type == "set") and stanza.tags[1].name == "query" then
			if self:get_affiliation(stanza.attr.from) ~= "owner" then
				origin.send(st.error_reply(stanza, "auth", "forbidden", "Only owners can configure rooms"));
			elseif stanza.attr.type == "get" then
				self:send_form(origin, stanza);
			elseif stanza.attr.type == "set" then
				local child = stanza.tags[1].tags[1];
				if not child then
					origin.send(st.error_reply(stanza, "modify", "bad-request"));
				elseif child.name == "destroy" then
					local newjid = child.attr.jid;
					local reason, password;
					for _,tag in ipairs(child.tags) do
						if tag.name == "reason" then
							reason = #tag.tags == 0 and tag[1];
						elseif tag.name == "password" then
							password = #tag.tags == 0 and tag[1];
						end
					end
					self:destroy(newjid, reason, password);
					origin.send(st.reply(stanza));
				else
					self:process_form(origin, stanza);
				end
			end
		elseif type == "set" or type == "get" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and type == "groupchat" then
		local from, to = stanza.attr.from, stanza.attr.to;
		local current_nick = self._jid_nick[from];
		local occupant = self._occupants[current_nick];
		if not occupant then -- not in room
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		elseif occupant.role == "visitor" then
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
		else
			local from = stanza.attr.from;
			stanza.attr.from = current_nick;
			local subject = getText(stanza, {"subject"});
			if subject then
				if occupant.role == "moderator" or
					( self._data.changesubject and occupant.role == "participant" ) then -- and participant
					self:set_subject(current_nick, subject); -- TODO use broadcast_message_stanza
				else
					stanza.attr.from = from;
					origin.send(st.error_reply(stanza, "auth", "forbidden"));
				end
			else
				self:broadcast_message(stanza, self:get_historylength() > 0 and stanza:get_child("body"));
			end
			stanza.attr.from = from;
		end
	elseif stanza.name == "message" and type == "error" and is_kickable_error(stanza) then
		local current_nick = self._jid_nick[stanza.attr.from];
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		self:handle_to_occupant(origin, build_unavailable_presence_from_error(stanza)); -- send unavailable
	elseif stanza.name == "presence" then -- hack - some buggy clients send presence updates to the room rather than their nick
		local to = stanza.attr.to;
		local current_nick = self._jid_nick[stanza.attr.from];
		if current_nick then
			stanza.attr.to = current_nick;
			self:handle_to_occupant(origin, stanza);
			stanza.attr.to = to;
		elseif type ~= "error" and type ~= "result" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif stanza.name == "message" and not(type == "chat" or type == "error" or type == "groupchat" or type == "headline") and #stanza.tags == 1
		and self._jid_nick[stanza.attr.from] and stanza.tags[1].name == "x" and stanza.tags[1].attr.xmlns == "http://jabber.org/protocol/muc#user" then
		local x = stanza.tags[1];
		local payload = (#x.tags == 1 and x.tags[1]);
		if payload and payload.name == "invite" and payload.attr.to then
			local _from, _to = stanza.attr.from, stanza.attr.to;
			local _invitee = jid_prep(payload.attr.to);
			if _invitee then
				local _reason = payload.tags[1] and payload.tags[1].name == 'reason' and #payload.tags[1].tags == 0 and payload.tags[1][1];
				local invite = st.message({from = _to, to = _invitee, id = stanza.attr.id})
					:tag('x', {xmlns='http://jabber.org/protocol/muc#user'})
						:tag('invite', {from=_from})
							:tag('reason'):text(_reason or ""):up()
						:up();
						if self:get_password() then
							invite:tag("password"):text(self:get_password()):up();
						end
					invite:up()
					:tag('x', {xmlns="jabber:x:conference", jid=_to}) -- COMPAT: Some older clients expect this
						:text(_reason or "")
					:up()
					:tag('body') -- Add a plain message for clients which don't support invites
						:text(_from..' invited you to the room '.._to..(_reason and (' ('.._reason..')') or ""))
					:up();
				if self:is_members_only() and not self:get_affiliation(_invitee) then
					log("debug", "%s invited %s into members only room %s, granting membership", _from, _invitee, _to);
					self:set_affiliation(_from, _invitee, "member", nil, "Invited by " .. self._jid_nick[_from])
				end
				self:_route_stanza(invite);
			else
				origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
			end
		else
			origin.send(st.error_reply(stanza, "cancel", "bad-request"));
		end
	else
		if type == "error" or type == "result" then return; end
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end
end

function room_mt:handle_stanza(origin, stanza)
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);
	if to_resource then
		self:handle_to_occupant(origin, stanza);
	else
		self:handle_to_room(origin, stanza);
	end
end

function room_mt:route_stanza(stanza) end -- Replace with a routing function, e.g., function(room, stanza) core_route_stanza(origin, stanza); end

function room_mt:get_affiliation(jid)
	local node, host, resource = jid_split(jid);
	local bare = node and node.."@"..host or host;
	local result = self._affiliations[bare]; -- Affiliations are granted, revoked, and maintained based on the user's bare JID.
	if not result and self._affiliations[host] == "outcast" then result = "outcast"; end -- host banned
	return result;
end
function room_mt:set_affiliation(actor, jid, affiliation, callback, reason)
	jid = jid_bare(jid);
	if affiliation == "none" then affiliation = nil; end
	if affiliation and affiliation ~= "outcast" and affiliation ~= "owner" and affiliation ~= "admin" and affiliation ~= "member" then
		return nil, "modify", "not-acceptable";
	end
	if actor ~= true then
		local actor_affiliation = self:get_affiliation(actor);
		local target_affiliation = self:get_affiliation(jid);
		if target_affiliation == affiliation then -- no change, shortcut
			if callback then callback(); end
			return true;
		end
		if actor_affiliation ~= "owner" then
			if affiliation == "owner" or affiliation == "admin" or actor_affiliation ~= "admin" or target_affiliation == "owner" or target_affiliation == "admin" then
				return nil, "cancel", "not-allowed";
			end
		elseif target_affiliation == "owner" and jid_bare(actor) == jid then -- self change
			local is_last = true;
			for j, aff in pairs(self._affiliations) do if j ~= jid and aff == "owner" then is_last = false; break; end end
			if is_last then
				return nil, "cancel", "conflict";
			end
		end
	end
	self._affiliations[jid] = affiliation;
	local role = self:get_default_role(affiliation);
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=affiliation or "none", role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	local presence_type = nil;
	if not role then -- getting kicked
		presence_type = "unavailable";
		if affiliation == "outcast" then
			x:tag("status", {code="301"}):up(); -- banned
		else
			x:tag("status", {code="321"}):up(); -- affiliation change
		end
	end
	local modified_nicks = {};
	for nick, occupant in pairs(self._occupants) do
		if jid_bare(occupant.jid) == jid then
			if not role then -- getting kicked
				self._occupants[nick] = nil;
			else
				occupant.affiliation, occupant.role = affiliation, role;
			end
			for jid,pres in pairs(occupant.sessions) do -- remove for all sessions of the nick
				if not role then self._jid_nick[jid] = nil; end
				local p = st.clone(pres);
				p.attr.from = nick;
				p.attr.type = presence_type;
				p.attr.to = jid;
				p:add_child(x);
				self:_route_stanza(p);
				if occupant.jid == jid then
					modified_nicks[nick] = p;
				end
			end
		end
	end
	if self.save then self:save(); end
	if callback then callback(); end
	for nick,p in pairs(modified_nicks) do
		p.attr.from = nick;
		self:broadcast_except_nick(p, nick);
	end
	return true;
end

function room_mt:get_role(nick)
	local session = self._occupants[nick];
	return session and session.role or nil;
end
function room_mt:can_set_role(actor_jid, occupant_jid, role)
	local occupant = self._occupants[occupant_jid];
	if not occupant or not actor_jid then return nil, "modify", "not-acceptable"; end

	if actor_jid == true then return true; end

	local actor = self._occupants[self._jid_nick[actor_jid]];
	if actor and actor.role == "moderator" then
		if occupant.affiliation ~= "owner" and occupant.affiliation ~= "admin" then
			if actor.affiliation == "owner" or actor.affiliation == "admin" then
				return true;
			elseif occupant.role ~= "moderator" and role ~= "moderator" then
				return true;
			end
		end
	end
	return nil, "cancel", "not-allowed";
end
function room_mt:set_role(actor, occupant_jid, role, callback, reason)
	if role == "none" then role = nil; end
	if role and role ~= "moderator" and role ~= "participant" and role ~= "visitor" then return nil, "modify", "not-acceptable"; end
	local allowed, err_type, err_condition = self:can_set_role(actor, occupant_jid, role);
	if not allowed then return allowed, err_type, err_condition; end
	local occupant = self._occupants[occupant_jid];
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
			:tag("item", {affiliation=occupant.affiliation or "none", nick=select(3, jid_split(occupant_jid)), role=role or "none"})
				:tag("reason"):text(reason or ""):up()
			:up();
	local presence_type = nil;
	if not role then -- kick
		presence_type = "unavailable";
		self._occupants[occupant_jid] = nil;
		for jid in pairs(occupant.sessions) do -- remove for all sessions of the nick
			self._jid_nick[jid] = nil;
		end
		x:tag("status", {code = "307"}):up();
	else
		occupant.role = role;
	end
	local bp;
	for jid,pres in pairs(occupant.sessions) do -- send to all sessions of the nick
		local p = st.clone(pres);
		p.attr.from = occupant_jid;
		p.attr.type = presence_type;
		p.attr.to = jid;
		p:add_child(x);
		self:_route_stanza(p);
		if occupant.jid == jid then
			bp = p;
		end
	end
	if callback then callback(); end
	if bp then
		self:broadcast_except_nick(bp, occupant_jid);
	end
	return true;
end

function room_mt:_route_stanza(stanza)
	local muc_child;
	local to_occupant = self._occupants[self._jid_nick[stanza.attr.to]];
	local from_occupant = self._occupants[stanza.attr.from];
	if stanza.name == "presence" then
		if to_occupant and from_occupant then
			if self._data.whois == 'anyone' then
			    muc_child = stanza:get_child("x", "http://jabber.org/protocol/muc#user");
			else
				if to_occupant.role == "moderator" or jid_bare(to_occupant.jid) == jid_bare(from_occupant.jid) then
					muc_child = stanza:get_child("x", "http://jabber.org/protocol/muc#user");
				end
			end
		end
	end
	if muc_child then
		for _, item in pairs(muc_child.tags) do
			if item.name == "item" then
				if from_occupant == to_occupant then
					item.attr.jid = stanza.attr.to;
				else
					item.attr.jid = from_occupant.jid;
				end
			end
		end
	end
	self:route_stanza(stanza);
	if muc_child then
		for _, item in pairs(muc_child.tags) do
			if item.name == "item" then
				item.attr.jid = nil;
			end
		end
	end
end

local _M = {}; -- module "muc"

function _M.new_room(jid, config)
	return setmetatable({
		jid = jid;
		_jid_nick = {};
		_occupants = {};
		_data = {
		    whois = 'moderators';
		    history_length = math.min((config and config.history_length)
		    	or default_history_length, max_history_length);
		};
		_affiliations = {};
	}, room_mt);
end

function _M.set_max_history_length(_max_history_length)
	max_history_length = _max_history_length or math.huge;
end

_M.room_mt = room_mt;

return _M;
