-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--



local t_insert = table.insert;
local jid_split = require "util.jid".split;
local ipairs = ipairs;
local st = require "util.stanza";

module "discohelper";

local function addDiscoItemsHandler(self, jid, func)
	if self.item_handlers[jid] then
		t_insert(self.item_handlers[jid], func);
	else
		self.item_handlers[jid] = {func};
	end
end

local function addDiscoInfoHandler(self, jid, func)
	if self.info_handlers[jid] then
		t_insert(self.info_handlers[jid], func);
	else
		self.info_handlers[jid] = {func};
	end
end

local function handle(self, stanza)
	if stanza.name == "iq" and stanza.tags[1].name == "query" then
		local query = stanza.tags[1];
		local to = stanza.attr.to;
		local from = stanza.attr.from
		local node = query.attr.node or "";
		local to_node, to_host = jid_split(to);

		local reply = st.reply(stanza):query(query.attr.xmlns);
		local handlers;
		if query.attr.xmlns == "http://jabber.org/protocol/disco#info" then -- select handler set
			handlers = self.info_handlers;
		elseif query.attr.xmlns == "http://jabber.org/protocol/disco#items" then
			handlers = self.item_handlers;
		end
		local handler;
		local found; -- to keep track of any handlers found
		if to_node then -- handlers which get called always
			handler = handlers["*node"];
		else
			handler = handlers["*host"];
		end
		if handler then -- call always called handler
			for _, h in ipairs(handler) do
				if h(reply, to, from, node) then found = true; end
			end
		end
		handler = handlers[to]; -- get the handler
		if not handler then -- if not found then use default handler
			if to_node then
				handler = handlers["*defaultnode"];
			else
				handler = handlers["*defaulthost"];
			end
		end
		if handler then
			for _, h in ipairs(handler) do
				if h(reply, to, from, node) then found = true; end
			end
		end
		if found then return reply; end -- return the reply if there was one
		return st.error_reply(stanza, "cancel", "service-unavailable");
	end
end

function new()
	return {
		item_handlers = {};
		info_handlers = {};
		addDiscoItemsHandler = addDiscoItemsHandler;
		addDiscoInfoHandler = addDiscoInfoHandler;
		handle = handle;
	};
end

return _M;
