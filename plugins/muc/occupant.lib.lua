local next = next;
local pairs = pairs;
local setmetatable = setmetatable;
local st = require "util.stanza";

local get_filtered_presence do
	local presence_filters = {
		["http://jabber.org/protocol/muc"] = true;
		["http://jabber.org/protocol/muc#user"] = true;
	}
	local function presence_filter(tag)
		if presence_filters[tag.attr.xmlns] then
			return nil;
		end
		return tag;
	end
	function get_filtered_presence(stanza)
		return st.clone(stanza):maptags(presence_filter);
	end
end

local occupant_mt = {};
occupant_mt.__index = occupant_mt;

local function new_occupant(bare_real_jid, nick)
	return setmetatable({
		bare_jid = bare_real_jid;
		nick = nick; -- in-room jid
		sessions = {}; -- hash from real_jid to presence stanzas. stanzas should not be modified
		role = nil;
		jid = nil; -- Primary session
	}, occupant_mt);
end

-- Deep copy an occupant
local function copy_occupant(occupant)
	local sessions = {};
	for full_jid, presence_stanza in pairs(occupant.sessions) do
		if presence_stanza.attr.type ~= "unavailable" then
			sessions[full_jid] = presence_stanza;
		end
	end
	return setmetatable({
		bare_jid = occupant.bare_jid;
		nick = occupant.nick;
		sessions = sessions;
		role = occupant.role;
		jid = occupant.jid;
	}, occupant_mt);
end

function occupant_mt:set_session(real_jid, presence_stanza, replace_primary)
	local pr = get_filtered_presence(presence_stanza);
	pr.attr.from = self.nick;
	pr.attr.to = real_jid;

	self.sessions[real_jid] = pr;
	if replace_primary or self.jid == nil then
		self.jid = real_jid;
	end
end

function occupant_mt:remove_session(real_jid)
	-- Delete original session
	local presence_stanza = self.sessions[real_jid];
	self.sessions[real_jid] = nil;
	if self.jid == real_jid then
		-- find another session to be the primary (might be nil)
		self.jid = next(self.sessions);
	end
end

function occupant_mt:each_session()
	return pairs(self.sessions)
end

function occupant_mt:get_presence(real_jid)
	return self.sessions[real_jid or self.jid]
end

return {
	new = new_occupant;
	copy = copy_occupant;
	mt = occupant_mt;
}
