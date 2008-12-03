-- Prosody IM v0.1
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



local datamanager = require "util.datamanager";
local st = require "util.stanza";
local datetime = require "util.datetime";
local ipairs = ipairs;

module "offlinemanager"

function store(node, host, stanza)
	stanza.attr.stamp = datetime.datetime();
	stanza.attr.stamp_legacy = datetime.legacy();
	return datamanager.list_append(node, host, "offline", st.preserialize(stanza));
end

function load(node, host)
	local data = datamanager.list_load(node, host, "offline");
	if not data then return; end
	for k, v in ipairs(data) do
		local stanza = st.deserialize(v);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = host, stamp = stanza.attr.stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = host, stamp = stanza.attr.stamp_legacy}):up(); -- XEP-0091 (deprecated)
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
		data[k] = stanza;
	end
	return data;
end

function deleteAll(node, host)
	return datamanager.list_store(node, host, "offline", nil);
end

return _M;
