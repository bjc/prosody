-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local select = select;
local pairs, ipairs = pairs, ipairs;
local next = next;
local setmetatable = setmetatable;
local t_insert, t_remove = table.insert, table.remove;

local gettime = os.time;
local datetime = require "util.datetime";

local dataform = require "util.dataforms";

local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local jid_prep = require "util.jid".prep;
local st = require "util.stanza";
local log = require "util.logger".init("mod_muc");
local base64 = require "util.encodings".base64;
local md5 = require "util.hashes".md5;

local occupant_lib = module:require "muc/occupant"

local default_history_length, max_history_length = 20, math.huge;

local is_kickable_error do
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
	function is_kickable_error(stanza)
		local cond = select(2, stanza:get_error()) or "malformed error";
		return kickable_error_conditions[cond];
	end
end

local room_mt = {};
room_mt.__index = room_mt;

function room_mt:__tostring()
	return "MUC room ("..self.jid..")";
end

function room_mt:get_occupant_jid(real_jid)
	return self._jid_nick[real_jid]
end

function room_mt:get_default_role(affiliation)
	if affiliation == "owner" or affiliation == "admin" then
		return "moderator";
	elseif affiliation == "member" then
		return "participant";
	elseif not affiliation then
		if not self:get_members_only() then
			return self:get_moderated() and "visitor" or "participant";
		end
	end
end

function room_mt:lock()
	self.locked = true
end
function room_mt:unlock()
	module:fire_event("muc-room-unlocked", { room = self });
	self.locked = nil
end
function room_mt:is_locked()
	return not not self.locked
end

--- Occupant functions
function room_mt:new_occupant(bare_real_jid, nick)
	local occupant = occupant_lib.new(bare_real_jid, nick);
	local affiliation = self:get_affiliation(bare_real_jid);
	occupant.role = self:get_default_role(affiliation);
	return occupant;
end

function room_mt:get_occupant_by_nick(nick)
	local occupant = self._occupants[nick];
	if occupant == nil then return nil end
	return occupant_lib.copy(occupant);
end

do
	local function next_copied_occupant(occupants, occupant_jid)
		local next_occupant_jid, raw_occupant = next(occupants, occupant_jid);
		if next_occupant_jid == nil then return nil end
		return next_occupant_jid, occupant_lib.copy(raw_occupant);
	end
	function room_mt:each_occupant(read_only)
		return next_copied_occupant, self._occupants, nil;
	end
end

function room_mt:get_occupant_by_real_jid(real_jid)
	local occupant_jid = self:get_occupant_jid(real_jid);
	if occupant_jid == nil then return nil end
	return self:get_occupant_by_nick(occupant_jid);
end

function room_mt:save_occupant(occupant)
	occupant = occupant_lib.copy(occupant); -- So that occupant can be modified more
	local id = occupant.nick

	-- Need to maintain _jid_nick secondary index
	local old_occupant = self._occupants[id];
	if old_occupant then
		for real_jid in pairs(old_occupant.sessions) do
			self._jid_nick[real_jid] = nil;
		end
	end
	if occupant.role ~= nil and next(occupant.sessions) then
		for real_jid, presence in occupant:each_session() do
			self._jid_nick[real_jid] = occupant.nick;
		end
	else
		occupant = nil
	end
	self._occupants[id] = occupant
end

function room_mt:route_to_occupant(occupant, stanza)
	local to = stanza.attr.to;
	for jid, pr in occupant:each_session() do
		if pr.attr.type ~= "unavailable" then
			stanza.attr.to = jid;
			self:route_stanza(stanza);
		end
	end
	stanza.attr.to = to;
end

-- Adds an item to an "x" element.
-- actor is the attribute table
local function add_item(x, affiliation, role, jid, nick, actor, reason)
	x:tag("item", {affiliation = affiliation; role = role; jid = jid; nick = nick;})
	if actor then
		x:tag("actor", actor):up()
	end
	if reason then
		x:tag("reason"):text(reason):up()
	end
	x:up();
	return x
end
-- actor is (real) jid
function room_mt:build_item_list(occupant, x, is_anonymous, nick, actor, reason)
	local affiliation = self:get_affiliation(occupant.bare_jid);
	local role = occupant.role;
	local actor_attr;
	if actor then
		actor_attr = {nick = select(3,jid_split(self:get_occupant_jid(actor)))};
	end
	if is_anonymous then
		add_item(x, affiliation, role, nil, nick, actor_attr, reason);
	else
		if actor_attr then
			actor_attr.jid = actor;
		end
		for real_jid, session in occupant:each_session() do
			add_item(x, affiliation, role, real_jid, nick, actor_attr, reason);
		end
	end
	return x
end

function room_mt:broadcast_message(stanza, historic)
	module:fire_event("muc-broadcast-message", {room = self, stanza = stanza, historic = historic});
	self:broadcast(stanza);
end

-- add to history
module:hook("muc-broadcast-message", function(event)
	if event.historic then
		local room = event.room
		local history = room._data['history'];
		if not history then history = {}; room._data['history'] = history; end
		local stanza = st.clone(event.stanza);
		stanza.attr.to = "";
		local ts = gettime();
		local stamp = datetime.datetime(ts);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = module.host, stamp = stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = module.host, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
		local entry = { stanza = stanza, timestamp = ts };
		t_insert(history, entry);
		while #history > room:get_historylength() do t_remove(history, 1) end
	end
end);

-- Broadcast a stanza to all occupants in the room.
-- optionally checks conditional called with (nick, occupant)
function room_mt:broadcast(stanza, cond_func)
	for nick, occupant in self:each_occupant() do
		if cond_func == nil or cond_func(nick, occupant) then
			self:route_to_occupant(occupant, stanza)
		end
	end
end

-- Broadcasts an occupant's presence to the whole room
-- Takes (and modifies) the x element that goes into the stanzas
function room_mt:publicise_occupant_status(occupant, full_x, actor, reason)
	local anon_x;
	local has_anonymous = self:get_whois() ~= "anyone";
	if has_anonymous then
		anon_x = st.clone(full_x);
		self:build_item_list(occupant, anon_x, true, nil, actor, reason);
	end
	self:build_item_list(occupant,full_x, false, nil, actor, reason);

	-- General populance
	local full_p
	if occupant.role ~= nil then
		-- Try to use main jid's presence
		local pr = occupant:get_presence();
		if pr ~= nil then
			full_p = st.clone(pr);
		end
	end
	if full_p == nil then
		full_p = st.presence{from=occupant.nick; type="unavailable"};
	end
	local anon_p;
	if has_anonymous then
		anon_p = st.clone(full_p);
		anon_p:add_child(anon_x);
	end
	full_p:add_child(full_x);

	for nick, n_occupant in self:each_occupant() do
		if nick ~= occupant.nick or n_occupant.role == nil then
			local pr = full_p;
			if has_anonymous and n_occupant.role ~= "moderators" and occupant.bare_jid ~= n_occupant.bare_jid then
				pr = anon_p;
			end
			self:route_to_occupant(n_occupant, pr);
		end
	end

	-- Presences for occupant itself
	full_x:tag("status", {code = "110";}):up();
	if occupant.role == nil then
		-- They get an unavailable
		self:route_to_occupant(occupant, full_p);
	else
		-- use their own presences as templates
		for full_jid, pr in occupant:each_session() do
			if pr.attr.type ~= "unavailable" then
				pr = st.clone(pr);
				pr.attr.to = full_jid;
				-- You can always see your own full jids
				pr:add_child(full_x);
				self:route_stanza(pr);
			end
		end
	end
end

function room_mt:send_occupant_list(to, filter)
	local to_occupant = self:get_occupant_by_real_jid(to);
	local has_anonymous = self:get_whois() ~= "anyone"
	for occupant_jid, occupant in self:each_occupant() do
		if filter == nil or filter(occupant_jid, occupant) then
			local x = st.stanza("x", {xmlns='http://jabber.org/protocol/muc#user'});
			local is_anonymous = has_anonymous and occupant.role ~= "moderator" and to_occupant.bare_jid ~= occupant.bare_jid;
			self:build_item_list(occupant, x, is_anonymous);
			local pres = st.clone(occupant:get_presence());
			pres.attr.to = to;
			pres:add_child(x);
			self:route_stanza(pres);
		end
	end
end

local function parse_history(stanza)
	local x_tag = stanza:get_child("x", "http://jabber.org/protocol/muc");
	local history_tag = x_tag and x_tag:get_child("history", "http://jabber.org/protocol/muc");
	if not history_tag then
		return nil, 20, nil
	end

	local maxchars = tonumber(history_tag.attr.maxchars);

	local maxstanzas = tonumber(history_tag.attr.maxstanzas);

	-- messages received since the UTC datetime specified
	local since = history_tag.attr.since;
	if since then
		since = datetime.parse(since);
	end

	-- messages received in the last "X" seconds.
	local seconds = tonumber(history_tag.attr.seconds);
	if seconds then
		seconds = gettime() - seconds
		if since then
			since = math.max(since, seconds);
		else
			since = seconds;
		end
	end

	return maxchars, maxstanzas, since
end

module:hook("muc-get-history", function(event)
	local room = event.room
	local history = room._data['history']; -- send discussion history
	if not history then return nil end
	local history_len = #history

	local to = event.to
	local maxchars = event.maxchars
	local maxstanzas = event.maxstanzas or history_len
	local since = event.since
	local n = 0;
	local charcount = 0;
	for i=history_len,1,-1 do
		local entry = history[i];
		if maxchars then
			if not entry.chars then
				entry.stanza.attr.to = "";
				entry.chars = #tostring(entry.stanza);
			end
			charcount = charcount + entry.chars + #to;
			if charcount > maxchars then break; end
		end
		if since and since > entry.timestamp then break; end
		if n + 1 > maxstanzas then break; end
		n = n + 1;
	end

	local i = history_len-n+1
	function event:next_stanza()
		if i > history_len then return nil end
		local entry = history[i]
		local msg = entry.stanza
		msg.attr.to = to;
		i = i + 1
		return msg
	end
	return true;
end);

function room_mt:send_history(stanza)
	local maxchars, maxstanzas, since = parse_history(stanza)
	local event = {
		room = self;
		to = stanza.attr.from; -- `to` is required to calculate the character count for `maxchars`
		maxchars = maxchars, maxstanzas = maxstanzas, since = since;
		next_stanza = function() end; -- events should define this iterator
	}
	module:fire_event("muc-get-history", event)
	for msg in event.next_stanza , event do
		self:route_stanza(msg);
	end
end

function room_mt:get_disco_info(stanza)
	local count = 0; for _ in self:each_occupant() do count = count + 1; end
	return st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category="conference", type="text", name=self:get_name()}):up()
		:tag("feature", {var="http://jabber.org/protocol/muc"}):up()
		:tag("feature", {var=self:get_password() and "muc_passwordprotected" or "muc_unsecured"}):up()
		:tag("feature", {var=self:get_moderated() and "muc_moderated" or "muc_unmoderated"}):up()
		:tag("feature", {var=self:get_members_only() and "muc_membersonly" or "muc_open"}):up()
		:tag("feature", {var=self:get_persistent() and "muc_persistent" or "muc_temporary"}):up()
		:tag("feature", {var=self:get_hidden() and "muc_hidden" or "muc_public"}):up()
		:tag("feature", {var=self:get_whois() ~= "anyone" and "muc_semianonymous" or "muc_nonanonymous"}):up()
		:add_child(dataform.new({
			{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/muc#roominfo" },
			{ name = "muc#roominfo_description", label = "Description", value = "" },
			{ name = "muc#roominfo_occupants", label = "Number of occupants", value = tostring(count) }
		}):form({["muc#roominfo_description"] = self:get_description()}, 'result'))
	;
end
function room_mt:get_disco_items(stanza)
	local reply = st.reply(stanza):query("http://jabber.org/protocol/disco#items");
	for room_jid in self:each_occupant() do
		reply:tag("item", {jid = room_jid, name = room_jid:match("/(.*)")}):up();
	end
	return reply;
end

function room_mt:get_subject()
	return self._data['subject'], self._data['subject_from']
end
local function create_subject_message(subject)
	return st.message({type='groupchat'})
		:tag('subject'):text(subject):up();
end
function room_mt:send_subject(to)
	local from, subject = self:get_subject()
	if subject then
		local msg = create_subject_message(subject)
		msg.attr.from = from
		msg.attr.to = to
		self:route_stanza(msg);
	end
end
function room_mt:set_subject(current_nick, subject)
	if subject == "" then subject = nil; end
	self._data['subject'] = subject;
	self._data['subject_from'] = current_nick;
	if self.save then self:save(); end
	local msg = create_subject_message(subject)
	msg.attr.from = current_nick
	self:broadcast_message(msg, false);
	return true;
end

function room_mt:handle_kickable(origin, stanza)
	local real_jid = stanza.attr.from;
	local occupant = self:get_occupant_by_real_jid(real_jid);
	if occupant == nil then return nil; end
	local type, condition, text = stanza:get_error();
	local error_message = "Kicked: "..(condition and condition:gsub("%-", " ") or "presence error");
	if text then
		error_message = error_message..": "..text;
	end
	occupant:set_session(real_jid, st.presence({type="unavailable"})
		:tag('status'):text(error_message));
	self:save_occupant(occupant);
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";})
		:tag("status", {code = "307"})
	self:publicise_occupant_status(occupant, x);
	return true;
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
function room_mt:get_moderated()
	return self._data.moderated;
end
function room_mt:set_members_only(members_only)
	members_only = members_only and true or nil;
	if self._data.members_only ~= members_only then
		self._data.members_only = members_only;
		if self.save then self:save(true); end
	end
end
function room_mt:get_members_only()
	return self._data.members_only;
end
function room_mt:set_persistent(persistent)
	persistent = persistent and true or nil;
	if self._data.persistent ~= persistent then
		self._data.persistent = persistent;
		if self.save then self:save(true); end
	end
end
function room_mt:get_persistent()
	return self._data.persistent;
end
function room_mt:set_hidden(hidden)
	hidden = hidden and true or nil;
	if self._data.hidden ~= hidden then
		self._data.hidden = hidden;
		if self.save then self:save(true); end
	end
end
function room_mt:get_hidden()
	return self._data.hidden;
end
function room_mt:get_public()
	return not self:get_hidden();
end
function room_mt:set_public(public)
	return self:set_hidden(not public);
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


local valid_whois = { moderators = true, anyone = true };

function room_mt:set_whois(whois)
	if valid_whois[whois] and self._data.whois ~= whois then
		self._data.whois = whois;
		if self.save then self:save(true); end
	end
end

function room_mt:get_whois()
	return self._data.whois;
end

module:hook("muc-room-pre-create", function(event)
	local room = event.room;
	if room:is_locked() and not event.stanza:get_child("x", "http://jabber.org/protocol/muc") then
		room:unlock(); -- Older groupchat protocol doesn't lock
	end
end, 10);

-- Give the room creator owner affiliation
module:hook("muc-room-pre-create", function(event)
	event.room:set_affiliation(true, jid_bare(event.stanza.attr.from), "owner");
end, -1);

module:hook("muc-occupant-pre-join", function(event)
	return module:fire_event("muc-occupant-pre-join/affiliation", event)
		or module:fire_event("muc-occupant-pre-join/password", event)
		or module:fire_event("muc-occupant-pre-join/locked", event);
end, -1)

module:hook("muc-occupant-pre-join/password", function(event)
	local room, stanza = event.room, event.stanza;
	local password = stanza:get_child("x", "http://jabber.org/protocol/muc");
	password = password and password:get_child_text("password", "http://jabber.org/protocol/muc");
	if not password or password == "" then password = nil; end
	if room:get_password() ~= password then
		local from, to = stanza.attr.from, stanza.attr.to;
		log("debug", "%s couldn't join due to invalid password: %s", from, to);
		local reply = st.error_reply(stanza, "auth", "not-authorized"):up();
		reply.tags[1].attr.code = "401";
		event.origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
		return true;
	end
end, -1);

module:hook("muc-occupant-pre-join/locked", function(event)
	if event.room:is_locked() then -- Deny entry
		event.origin.send(st.error_reply(event.stanza, "cancel", "item-not-found"));
		return true;
	end
end, -1);

-- registration required for entering members-only room
module:hook("muc-occupant-pre-join/affiliation", function(event)
	local room, stanza = event.room, event.stanza;
	local affiliation = room:get_affiliation(stanza.attr.from);
	if affiliation == nil and event.room:get_members_only() then
		local reply = st.error_reply(stanza, "auth", "registration-required"):up();
		reply.tags[1].attr.code = "407";
		event.origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
		return true;
	end
end, -1);

-- check if user is banned
module:hook("muc-occupant-pre-join/affiliation", function(event)
	local room, stanza = event.room, event.stanza;
	local affiliation = room:get_affiliation(stanza.attr.from);
	if affiliation == "outcast" then
		local reply = st.error_reply(stanza, "auth", "forbidden"):up();
		reply.tags[1].attr.code = "403";
		event.origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
		return true;
	end
end, -1);

module:hook("muc-occupant-joined", function(event)
	local room, stanza = event.room, event.stanza;
	local real_jid = stanza.attr.from;
	room:send_occupant_list(real_jid, function(nick, occupant)
		-- Don't include self
		return occupant.sessions[real_jid] == nil
	end);
	room:send_history(stanza);
	room:send_subject(real_jid);
end, -1);

function room_mt:handle_presence_to_occupant(origin, stanza)
	local type = stanza.attr.type;
	if type == "error" then -- error, kick em out!
		return self:handle_kickable(origin, stanza)
	elseif type == nil or type == "unavailable" then
		local real_jid = stanza.attr.from;
		local bare_jid = jid_bare(real_jid);
		local orig_occupant, dest_occupant;
		local is_new_room = next(self._affiliations) == nil;
		if is_new_room then
			if type == "unavailable" then return true; end -- Unavailable from someone not in the room
			if module:fire_event("muc-room-pre-create", {
					room = self;
					origin = origin;
					stanza = stanza;
				}) then return true; end
		else
			orig_occupant = self:get_occupant_by_real_jid(real_jid);
			if type == "unavailable" and orig_occupant == nil then return true; end -- Unavailable from someone not in the room
		end
		local is_first_dest_session;
		if type == "unavailable" then
			-- dest_occupant = nil
		elseif orig_occupant and orig_occupant.nick == stanza.attr.to then -- Just a presence update
			log("debug", "presence update for %s from session %s", orig_occupant.nick, real_jid);
			dest_occupant = orig_occupant;
		else
			local dest_jid = stanza.attr.to;
			dest_occupant = self:get_occupant_by_nick(dest_jid);
			if dest_occupant == nil then
				log("debug", "no occupant found for %s; creating new occupant object for %s", dest_jid, real_jid);
				is_first_dest_session = true;
				dest_occupant = self:new_occupant(bare_jid, dest_jid);
			else
				is_first_dest_session = false;
			end
		end
		local is_last_orig_session;
		if orig_occupant ~= nil then
			-- Is there are least 2 sessions?
			is_last_orig_session = next(orig_occupant.sessions, next(orig_occupant.sessions)) == nil;
		end

		local event, event_name = {
			room = self;
			origin = origin;
			stanza = stanza;
			is_first_session = is_first_dest_session;
			is_last_session = is_last_orig_session;
		};
		if orig_occupant == nil then
			event_name = "muc-occupant-pre-join";
			event.is_new_room = is_new_room;
		elseif dest_occupant == nil then
			event_name = "muc-occupant-pre-leave";
		else
			event_name = "muc-occupant-pre-change";
		end
		if module:fire_event(event_name, event) then return true; end

		-- Check for nick conflicts
		if dest_occupant ~= nil and not is_first_dest_session and bare_jid ~= jid_bare(dest_occupant.bare_jid) then -- new nick or has different bare real jid
			log("debug", "%s couldn't join due to nick conflict: %s", real_jid, dest_occupant.nick);
			local reply = st.error_reply(stanza, "cancel", "conflict"):up();
			reply.tags[1].attr.code = "409";
			origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
			return true;
		end

		-- Send presence stanza about original occupant
		if orig_occupant ~= nil and orig_occupant ~= dest_occupant then
			local orig_x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";});

			if dest_occupant == nil then -- Session is leaving
				log("debug", "session %s is leaving occupant %s", real_jid, orig_occupant.nick);
				orig_occupant:set_session(real_jid, stanza);
			else
				log("debug", "session %s is changing from occupant %s to %s", real_jid, orig_occupant.nick, dest_occupant.nick);
				orig_occupant:remove_session(real_jid); -- If we are moving to a new nick; we don't want to get our own presence

				local dest_nick = select(3, jid_split(dest_occupant.nick));
				local affiliation = self:get_affiliation(bare_jid);

				-- This session
				if not is_first_dest_session then -- User is swapping into another pre-existing session
					log("debug", "session %s is swapping into multisession %s, showing it leave.", real_jid, dest_occupant.nick);
					-- Show the other session leaving
					local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";})
						:tag("status"):text("you are joining pre-existing session " .. dest_nick):up();
					add_item(x, affiliation, "none");
					local pr = st.presence{from = dest_occupant.nick, to = real_jid, type = "unavailable"}
						:add_child(x);
					self:route_stanza(pr);
				else
					if is_last_orig_session then -- User is moving to a new session
						log("debug", "no sessions in %s left; marking as nick change", orig_occupant.nick);
						-- Everyone gets to see this as a nick change
						local jid = self:get_whois() ~= "anyone" and real_jid or nil; -- FIXME: mods should see real jids
						add_item(orig_x, affiliation, orig_occupant.role, jid, dest_nick);
						orig_x:tag("status", {code = "303";}):up();
					end
				end
				-- The session itself always sees a nick change
				local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";});
				add_item(x, affiliation, orig_occupant.role, real_jid, dest_nick);
				-- self:build_item_list(orig_occupant, x, false); -- COMPAT
				x:tag("status", {code = "303";}):up();
				x:tag("status", {code = "110";}):up();
				self:route_stanza(st.presence{from = dest_occupant.nick, to = real_jid, type = "unavailable"}:add_child(x));
			end
			self:save_occupant(orig_occupant);
			self:publicise_occupant_status(orig_occupant, orig_x);

			if is_last_orig_session then
				module:fire_event("muc-occupant-left", {room = self; nick = orig_occupant.nick;});
			end
		end

		if dest_occupant ~= nil then
			dest_occupant:set_session(real_jid, stanza);
			local dest_x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";});
			if is_new_room then
				dest_x:tag("status", {code = "201"}):up();
			end
			if orig_occupant == nil and self:get_whois() == "anyone" then
				dest_x:tag("status", {code = "100"}):up();
			end
			self:save_occupant(dest_occupant);
			self:publicise_occupant_status(dest_occupant, dest_x);

			if orig_occupant ~= nil and orig_occupant ~= dest_occupant and not is_last_orig_session then -- If user is swapping and wasn't last original session
				log("debug", "session %s split nicks; showing %s rejoining", real_jid, orig_occupant.nick);
				-- Show the original nick joining again
				local pr = st.clone(orig_occupant:get_presence());
				pr.attr.to = real_jid;
				local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user";});
				self:build_item_list(orig_occupant, x, false);
				-- TODO: new status code to inform client this was the multi-session it left?
				pr:add_child(x);
				self:route_stanza(pr);
			end

			if orig_occupant == nil and is_first_dest_session then
				module:fire_event("muc-occupant-joined", {room = self; nick = dest_occupant.nick; stanza = stanza;});
			end
		end
	elseif type ~= 'result' then -- bad type
		if type ~= 'visible' and type ~= 'invisible' then -- COMPAT ejabberd can broadcast or forward XEP-0018 presences
			origin.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME correct error?
		end
	end
	return true;
end

function room_mt:handle_iq_to_occupant(origin, stanza)
	local from, to = stanza.attr.from, stanza.attr.to;
	local type = stanza.attr.type;
	local id = stanza.attr.id;
	local current_nick = self:get_occupant_jid(from);
	local occupant = self:get_occupant_by_nick(to);
	if (type == "error" or type == "result") then
		do -- deconstruct_stanza_id
			if not current_nick or not occupant then return nil; end
			local from_jid, id, to_jid_hash = (base64.decode(stanza.attr.id) or ""):match("^(.+)%z(.*)%z(.+)$");
			if not(from == from_jid or from == jid_bare(from_jid)) then return nil; end
			local session_jid
			for to_jid in occupant:each_session() do
				if md5(to_jid) == to_jid_hash then
					session_jid = to_jid;
					break;
				end
			end
			if session_jid == nil then return nil; end
			stanza.attr.from, stanza.attr.to, stanza.attr.id = current_nick, session_jid, id
		end
		log("debug", "%s sent private iq stanza to %s (%s)", from, to, stanza.attr.to);
		self:route_stanza(stanza);
		stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
		return true;
	else -- Type is "get" or "set"
		if not current_nick then
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
			return true;
		end
		if not occupant then -- recipient not in room
			origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
			return true;
		end
		do -- construct_stanza_id
			stanza.attr.id = base64.encode(occupant.jid.."\0"..stanza.attr.id.."\0"..md5(from));
		end
		stanza.attr.from, stanza.attr.to = current_nick, occupant.jid;
		log("debug", "%s sent private iq stanza to %s (%s)", from, to, occupant.jid);
		if stanza.tags[1].attr.xmlns == 'vcard-temp' then
			stanza.attr.to = jid_bare(stanza.attr.to);
		end
		self:route_stanza(stanza);
		stanza.attr.from, stanza.attr.to, stanza.attr.id = from, to, id;
		return true;
	end
end

function room_mt:handle_message_to_occupant(origin, stanza)
	local from, to = stanza.attr.from, stanza.attr.to;
	local current_nick = self:get_occupant_jid(from);
	local type = stanza.attr.type;
	if not current_nick then -- not in room
		if type ~= "error" then
			origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		end
		return true;
	end
	if type == "groupchat" then -- groupchat messages not allowed in PM
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
		return true;
	elseif type == "error" and is_kickable_error(stanza) then
		log("debug", "%s kicked from %s for sending an error message", current_nick, self.jid);
		return self:handle_kickable(origin, stanza); -- send unavailable
	end

	local o_data = self:get_occupant_by_nick(to);
	if not o_data then
		origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Recipient not in room"));
		return true;
	end
	log("debug", "%s sent private message stanza to %s (%s)", from, to, o_data.jid);
	stanza:tag("x", { xmlns = "http://jabber.org/protocol/muc#user" }):up();
	stanza.attr.from = current_nick;
	self:route_to_occupant(o_data, stanza)
	-- TODO: Remove x tag?
	stanza.attr.from = from;
	return true;
end

function room_mt:send_form(origin, stanza)
	origin.send(st.reply(stanza):query("http://jabber.org/protocol/muc#owner")
		:add_child(self:get_form_layout(stanza.attr.from):form())
	);
end

function room_mt:get_form_layout(actor)
	local whois = self:get_whois()
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
			value = self:get_persistent()
		},
		{
			name = 'muc#roomconfig_publicroom',
			type = 'boolean',
			label = 'Make Room Publicly Searchable?',
			value = not self:get_hidden()
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
				{ value = 'moderators', label = 'Moderators Only', default = whois == 'moderators' },
				{ value = 'anyone',     label = 'Anyone',          default = whois == 'anyone' }
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
			value = self:get_moderated()
		},
		{
			name = 'muc#roomconfig_membersonly',
			type = 'boolean',
			label = 'Make Room Members-Only?',
			value = self:get_members_only()
		},
		{
			name = 'muc#roomconfig_historylength',
			type = 'text-single',
			label = 'Maximum Number of History Messages Returned by Room',
			value = tostring(self:get_historylength())
		}
	});
	return module:fire_event("muc-config-form", { room = self, actor = actor, form = form }) or form;
end

function room_mt:process_form(origin, stanza)
	local query = stanza.tags[1];
	local form = query:get_child("x", "jabber:x:data")
	if not form then origin.send(st.error_reply(stanza, "cancel", "service-unavailable")); return; end
	if form.attr.type == "cancel" then origin.send(st.reply(stanza)); return; end
	if form.attr.type ~= "submit" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Not a submitted form")); return; end

	local fields = self:get_form_layout(stanza.attr.from):data(form);
	if fields.FORM_TYPE ~= "http://jabber.org/protocol/muc#roomconfig" then origin.send(st.error_reply(stanza, "cancel", "bad-request", "Form is not of type room configuration")); return; end


	local changed = {};

	local function handle_option(name, field, allowed)
		local new = fields[field];
		if new == nil then return; end
		if allowed and not allowed[new] then return; end
		if new == self["get_"..name](self) then return; end
		changed[name] = true;
		self["set_"..name](self, new);
	end

	local event = { room = self, fields = fields, changed = changed, stanza = stanza, origin = origin, update_option = handle_option };
	module:fire_event("muc-config-submitted", event);

	handle_option("name", "muc#roomconfig_roomname");
	handle_option("description", "muc#roomconfig_roomdesc");
	handle_option("persistent", "muc#roomconfig_persistentroom");
	handle_option("moderated", "muc#roomconfig_moderatedroom");
	handle_option("members_only", "muc#roomconfig_membersonly");
	handle_option("public", "muc#roomconfig_publicroom");
	handle_option("changesubject", "muc#roomconfig_changesubject");
	handle_option("historylength", "muc#roomconfig_historylength");
	handle_option("whois", "muc#roomconfig_whois", valid_whois);
	handle_option("password", "muc#roomconfig_roomsecret");

	if self.save then self:save(true); end
	if self:is_locked() then
		self:unlock();
	end
	origin.send(st.reply(stanza));

	if next(changed) then
		local msg = st.message({type='groupchat', from=self.jid})
			:tag('x', {xmlns='http://jabber.org/protocol/muc#user'}):up()
				:tag('status', {code = '104'}):up();
		if changed.whois then
			local code = (self:get_whois() == 'moderators') and "173" or "172";
			msg.tags[1]:tag('status', {code = code}):up();
		end
		self:broadcast_message(msg, false)
	end
end

-- Removes everyone from the room
function room_mt:clear(x)
	x = x or st.stanza("x", {xmlns='http://jabber.org/protocol/muc#user'});
	local occupants_updated = {};
	for nick, occupant in self:each_occupant() do
		occupant.role = nil;
		self:save_occupant(occupant);
		occupants_updated[occupant] = true;
	end
	for occupant in pairs(occupants_updated) do
		self:publicise_occupant_status(occupant, x);
		module:fire_event("muc-occupant-left", { room = self; nick = occupant.nick; });
	end
end

function room_mt:destroy(newjid, reason, password)
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"})
		:tag("item", { affiliation='none', role='none' }):up()
		:tag("destroy", {jid=newjid});
	if reason then x:tag("reason"):text(reason):up(); end
	if password then x:tag("password"):text(password):up(); end
	x:up();
	self:clear(x);
	self:set_persistent(false);
	module:fire_event("muc-room-destroyed", { room = self });
end

function room_mt:handle_disco_info_get_query(origin, stanza)
	origin.send(self:get_disco_info(stanza));
	return true;
end

function room_mt:handle_disco_items_get_query(origin, stanza)
	origin.send(self:get_disco_items(stanza));
	return true;
end

function room_mt:handle_admin_query_set_command(origin, stanza)
	local item = stanza.tags[1].tags[1];
	if item.attr.jid then -- Validate provided JID
		item.attr.jid = jid_prep(item.attr.jid);
		if not item.attr.jid then
			origin.send(st.error_reply(stanza, "modify", "jid-malformed"));
			return true;
		end
	end
	if not item.attr.jid and item.attr.nick then -- COMPAT Workaround for Miranda sending 'nick' instead of 'jid' when changing affiliation
		local occupant = self:get_occupant_by_nick(self.jid.."/"..item.attr.nick);
		if occupant then item.attr.jid = occupant.jid; end
	elseif not item.attr.nick and item.attr.jid then
		local nick = self:get_occupant_jid(item.attr.jid);
		if nick then item.attr.nick = select(3, jid_split(nick)); end
	end
	local actor = stanza.attr.from;
	local reason = item:get_child_text("reason");
	local success, errtype, err
	if item.attr.affiliation and item.attr.jid and not item.attr.role then
		success, errtype, err = self:set_affiliation(actor, item.attr.jid, item.attr.affiliation, reason);
	elseif item.attr.role and item.attr.nick and not item.attr.affiliation then
		success, errtype, err = self:set_role(actor, self.jid.."/"..item.attr.nick, item.attr.role, reason);
	else
		success, errtype, err = nil, "cancel", "bad-request";
	end
	if not success then origin.send(st.error_reply(stanza, errtype, err)); end
	origin.send(st.reply(stanza));
	return true;
end

function room_mt:handle_admin_query_get_command(origin, stanza)
	local actor = stanza.attr.from;
	local affiliation = self:get_affiliation(actor);
	local item = stanza.tags[1].tags[1];
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
			return true;
		else
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
			return true;
		end
	elseif _rol and not _aff then
		local role = self:get_role(self:get_occupant_jid(actor)) or self:get_default_role(affiliation);
		if role == "moderator" then
			if _rol == "none" then _rol = nil; end
			self:send_occupant_list(actor, function(occupant_jid, occupant) return occupant.role == _rol end);
			return true;
		else
			origin.send(st.error_reply(stanza, "auth", "forbidden"));
			return true;
		end
	else
		origin.send(st.error_reply(stanza, "cancel", "bad-request"));
		return true;
	end
end

function room_mt:handle_owner_query_get_to_room(origin, stanza)
	if self:get_affiliation(stanza.attr.from) ~= "owner" then
		origin.send(st.error_reply(stanza, "auth", "forbidden", "Only owners can configure rooms"));
		return true;
	end

	self:send_form(origin, stanza);
	return true;
end
function room_mt:handle_owner_query_set_to_room(origin, stanza)
	if self:get_affiliation(stanza.attr.from) ~= "owner" then
		origin.send(st.error_reply(stanza, "auth", "forbidden", "Only owners can configure rooms"));
		return true;
	end

	local child = stanza.tags[1].tags[1];
	if not child then
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
		return true;
	elseif child.name == "destroy" then
		local newjid = child.attr.jid;
		local reason = child:get_child_text("reason");
		local password = child:get_child_text("password");
		self:destroy(newjid, reason, password);
		origin.send(st.reply(stanza));
		return true;
	else
		self:process_form(origin, stanza);
		return true;
	end
end

function room_mt:handle_groupchat_to_room(origin, stanza)
	local from = stanza.attr.from;
	local occupant = self:get_occupant_by_real_jid(from);
	if not occupant then -- not in room
		origin.send(st.error_reply(stanza, "cancel", "not-acceptable"));
		return true;
	elseif occupant.role == "visitor" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	else
		local from = stanza.attr.from;
		stanza.attr.from = occupant.nick;
		local subject = stanza:get_child_text("subject");
		if subject then
			if occupant.role == "moderator" or
				( self:get_changesubject() and occupant.role == "participant" ) then -- and participant
				self:set_subject(occupant.nick, subject);
			else
				stanza.attr.from = from;
				origin.send(st.error_reply(stanza, "auth", "forbidden"));
			end
		else
			self:broadcast_message(stanza, self:get_historylength() > 0 and stanza:get_child("body"));
		end
		stanza.attr.from = from;
		return true;
	end
end

-- hack - some buggy clients send presence updates to the room rather than their nick
function room_mt:handle_presence_to_room(origin, stanza)
	local current_nick = self:get_occupant_jid(stanza.attr.from);
	local handled
	if current_nick then
		local to = stanza.attr.to;
		stanza.attr.to = current_nick;
		handled = self:handle_presence_to_occupant(origin, stanza);
		stanza.attr.to = to;
	end
	return handled;
end

function room_mt:handle_mediated_invite(origin, stanza)
	local payload = stanza:get_child("x", "http://jabber.org/protocol/muc#user"):get_child("invite")
	local _from, _to = stanza.attr.from, stanza.attr.to;
	local current_nick = self:get_occupant_jid(_from)
	-- Need visitor role or higher to invite
	if not self:get_role(current_nick) or not self:get_default_role(self:get_affiliation(_from)) then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end
	local _invitee = jid_prep(payload.attr.to);
	if _invitee then
		local _reason = payload:get_child_text("reason");
		if self:get_whois() == "moderators" then
			_from = current_nick;
		end
		local invite = st.message({from = _to, to = _invitee, id = stanza.attr.id})
			:tag('x', {xmlns='http://jabber.org/protocol/muc#user'})
				:tag('invite', {from=_from})
					:tag('reason'):text(_reason or ""):up()
				:up();
		local password = self:get_password();
		if password then
			invite:tag("password"):text(password):up();
		end
			invite:up()
			:tag('x', {xmlns="jabber:x:conference", jid=_to}) -- COMPAT: Some older clients expect this
				:text(_reason or "")
			:up()
			:tag('body') -- Add a plain message for clients which don't support invites
				:text(_from..' invited you to the room '.._to..(_reason and (' ('.._reason..')') or ""))
			:up();
		module:fire_event("muc-invite", {room = self, stanza = invite, origin = origin, incoming = stanza});
		return true;
	else
		origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
		return true;
	end
end

module:hook("muc-invite", function(event)
	event.room:route_stanza(event.stanza);
	return true;
end, -1)

-- When an invite is sent; add an affiliation for the invitee
module:hook("muc-invite", function(event)
	local room, stanza = event.room, event.stanza
	local invitee = stanza.attr.to
	if room:get_members_only() and not room:get_affiliation(invitee) then
		local from = stanza:get_child("x", "http://jabber.org/protocol/muc#user"):get_child("invite").attr.from
		local current_nick = room:get_occupant_jid(from)
		log("debug", "%s invited %s into members only room %s, granting membership", from, invitee, room.jid);
		room:set_affiliation(from, invitee, "member", "Invited by " .. current_nick)
	end
end);

function room_mt:handle_mediated_decline(origin, stanza)
	local payload = stanza:get_child("x", "http://jabber.org/protocol/muc#user"):get_child("decline")
	local declinee = jid_prep(payload.attr.to);
	if declinee then
		local from, to = stanza.attr.from, stanza.attr.to;
		-- TODO: Validate declinee
		local reason = payload:get_child_text("reason")
		local decline = st.message({from = to, to = declinee, id = stanza.attr.id})
			:tag('x', {xmlns='http://jabber.org/protocol/muc#user'})
				:tag('decline', {from=from})
					:tag('reason'):text(reason or ""):up()
				:up()
			:up()
			:tag('body') -- Add a plain message for clients which don't support declines
				:text(from..' declined your invite to the room '..to..(reason and (' ('..reason..')') or ""))
			:up();
		module:fire_event("muc-decline", { room = self, stanza = decline, origin = origin, incoming = stanza });
		return true;
	else
		origin.send(st.error_reply(stanza, "cancel", "jid-malformed"));
		return true;
	end
end

module:hook("muc-decline", function(event)
	local room, stanza = event.room, event.stanza
	local occupant = room:get_occupant_by_real_jid(stanza.attr.to);
	if occupant then
		room:route_to_occupant(occupant, stanza)
	else
		room:route_stanza(stanza);
	end
	return true;
end, -1)

function room_mt:handle_message_to_room(origin, stanza)
	local type = stanza.attr.type;
	if type == "groupchat" then
		return self:handle_groupchat_to_room(origin, stanza)
	elseif type == "error" and is_kickable_error(stanza) then
		return self:handle_kickable(origin, stanza)
	elseif type == nil then
		local x = stanza:get_child("x", "http://jabber.org/protocol/muc#user");
		if x then
			local payload = x.tags[1];
			if payload == nil then
				-- fallthrough
			elseif payload.name == "invite" and payload.attr.to then
				return self:handle_mediated_invite(origin, stanza)
			elseif payload.name == "decline" and payload.attr.to then
				return self:handle_mediated_decline(origin, stanza)
			end
			origin.send(st.error_reply(stanza, "cancel", "bad-request"));
			return true;
		end
	end
end

function room_mt:route_stanza(stanza)
	module:send(stanza);
end

function room_mt:get_affiliation(jid)
	local node, host, resource = jid_split(jid);
	local bare = node and node.."@"..host or host;
	local result = self._affiliations[bare]; -- Affiliations are granted, revoked, and maintained based on the user's bare JID.
	if not result and self._affiliations[host] == "outcast" then result = "outcast"; end -- host banned
	return result;
end
function room_mt:set_affiliation(actor, jid, affiliation, reason)
	jid = jid_bare(jid);
	if affiliation == "none" then affiliation = nil; end
	if affiliation and affiliation ~= "outcast" and affiliation ~= "owner" and affiliation ~= "admin" and affiliation ~= "member" then
		return nil, "modify", "not-acceptable";
	end
	if actor ~= true then
		local actor_affiliation = self:get_affiliation(actor);
		local target_affiliation = self:get_affiliation(jid);
		if target_affiliation == affiliation then -- no change, shortcut
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
	local occupants_updated = {};
	for nick, occupant in self:each_occupant() do
		if occupant.bare_jid == jid then
			occupant.role = role;
			self:save_occupant(occupant);
			occupants_updated[occupant] = true;
		end
	end
	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"});
	if not role then -- getting kicked
		if affiliation == "outcast" then
			x:tag("status", {code="301"}):up(); -- banned
		else
			x:tag("status", {code="321"}):up(); -- affiliation change
		end
	end
	for occupant in pairs(occupants_updated) do
		self:publicise_occupant_status(occupant, x, actor, reason);
	end
	if self.save then self:save(); end
	return true;
end

function room_mt:get_role(nick)
	local occupant = self:get_occupant_by_nick(nick);
	return occupant and occupant.role or nil;
end

local valid_roles = {
	none = true;
	visitor = true;
	participant = true;
	moderator = true;
}
function room_mt:set_role(actor, occupant_jid, role, reason)
	if not actor then return nil, "modify", "not-acceptable"; end

	local occupant = self:get_occupant_by_nick(occupant_jid);
	if not occupant then return nil, "modify", "not-acceptable"; end

	if valid_roles[role or "none"] == nil then
		return nil, "modify", "not-acceptable";
	end
	role = role ~= "none" and role or nil; -- coerces `role == false` to `nil`

	if actor ~= true then
		-- Can't do anything to other owners or admins
		local occupant_affiliation = self:get_affiliation(occupant.bare_jid);
		if occupant_affiliation == "owner" and occupant_affiliation == "admin" then
			return nil, "cancel", "not-allowed";
		end

		-- If you are trying to give or take moderator role you need to be an owner or admin
		if occupant.role == "moderator" or role == "moderator" then
			local actor_affiliation = self:get_affiliation(actor);
			if actor_affiliation ~= "owner" and actor_affiliation ~= "admin" then
				return nil, "cancel", "not-allowed";
			end
		end

		-- Need to be in the room and a moderator
		local actor_occupant = self:get_occupant_by_real_jid(actor);
		if not actor_occupant or actor_occupant.role ~= "moderator" then
			return nil, "cancel", "not-allowed";
		end
	end

	local x = st.stanza("x", {xmlns = "http://jabber.org/protocol/muc#user"});
	if not role then
		x:tag("status", {code = "307"}):up();
	end
	occupant.role = role;
	self:save_occupant(occupant);
	self:publicise_occupant_status(occupant, x, actor, reason);
	return true;
end

local _M = {}; -- module "muc"

function _M.new_room(jid, config)
	return setmetatable({
		jid = jid;
		locked = nil;
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
