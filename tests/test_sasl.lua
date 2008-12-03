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


--- WARNING! ---
-- This file contains a mix of encodings below. 
-- Many editors will unquestioningly convert these for you.
-- Please be careful :(  (I recommend Scite)
---------------------------------

local	gmatch = string.gmatch;
local	t_concat, t_insert = table.concat, table.insert;
local	to_byte, to_char = string.byte, string.char;

local function _latin1toutf8(str)
		if not str then return str; end
                local p = {};
                for ch in gmatch(str, ".") do
                        ch = to_byte(ch);
                        if (ch < 0x80) then
                                t_insert(p, to_char(ch));
                        elseif (ch < 0xC0) then
                                t_insert(p, to_char(0xC2, ch));
                        else
                                t_insert(p, to_char(0xC3, ch - 64));
                        end
                end
                return t_concat(p);
        end

function latin1toutf8()
	local function assert_utf8(latin, utf8)
			assert_equal(_latin1toutf8(latin), utf8, "Incorrect UTF8 from Latin1: "..tostring(latin));
	end
	
	assert_utf8("", "")
	assert_utf8("test", "test")
	assert_utf8(nil, nil)
	assert_utf8("foobar.råkat.se", "foobar.rÃ¥kat.se")
end
