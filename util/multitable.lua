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



local select = select;
local t_insert = table.insert;
local pairs = pairs;
local next = next;

module "multitable"

local function get(self, ...)
	local t = self.data;
	for n = 1,select('#', ...) do
		t = t[select(n, ...)];
		if not t then break; end
	end
	return t;
end

local function add(self, ...)
	local t = self.data;
	local count = select('#', ...);
	for n = 1,count-1 do
		local key = select(n, ...);
		local tab = t[key];
		if not tab then tab = {}; t[key] = tab; end
		t = tab;
	end
	t_insert(t, (select(count, ...)));
end

local function set(self, ...)
	local t = self.data;
	local count = select('#', ...);
	for n = 1,count-2 do
		local key = select(n, ...);
		local tab = t[key];
		if not tab then tab = {}; t[key] = tab; end
		t = tab;
	end
	t[(select(count-1, ...))] = (select(count, ...));
end

local function r(t, n, _end, ...)
	if t == nil then return; end
	local k = select(n, ...);
	if n == _end then
		t[k] = nil;
		return;
	end
	if k then
		v = t[k];
		if v then
			r(v, n+1, _end, ...);
			if not next(v) then
				t[k] = nil;
			end
		end
	else
		for _,b in pairs(t) do
			r(b, n+1, _end, ...);
			if not next(b) then
				t[_] = nil;
			end
		end
	end
end

local function remove(self, ...)
	local _end = select('#', ...);
	for n = _end,1 do
		if select(n, ...) then _end = n; break; end
	end
	r(self.data, 1, _end, ...);
end


function new()
	return {
		data = {};
		get = get;
		add = add;
		set = set;
		remove = remove;
	};
end

return _M;
