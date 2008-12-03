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


-- XEP-0082: XMPP Date and Time Profiles

local os_date = os.date;
local error = error;

module "datetime"

function date()
	return os_date("!%Y-%m-%d");
end

function datetime()
	return os_date("!%Y-%m-%dT%H:%M:%SZ");
end

function time()
	return os_date("!%H:%M:%S");
end

function legacy()
	return os_date("!%Y%m%dT%H:%M:%S");
end

function parse(s)
	error("datetime.parse: Not implemented"); -- TODO
end

return _M;
