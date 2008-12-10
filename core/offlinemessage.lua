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



require "util.datamanager"

local datamanager = datamanager;
local t_insert = table.insert;

module "offlinemessage"

function new(user, host, stanza)
	local offlinedata = datamanager.load(user, host, "offlinemsg") or {};
	t_insert(offlinedata, stanza);
	return datamanager.store(user, host, "offlinemsg", offlinedata);
end

return _M;