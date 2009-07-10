-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local httpserver = require "net.httpserver";
local t_concat, t_insert = table.concat, table.insert;

local log = log;

local response_404 = { status = "404 Not Found", body = "<h1>No such action</h1>Sorry, I don't have the action you requested" };

local control = require "core.actions".actions;


local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = string.char(tonumber("0x"..k)); return t[k]; end });

local function urldecode(s)
                return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
end

local function query_to_table(query)
        if type(query) == "string" and #query > 0 then
                if query:match("=") then
                        local params = {};
                        for k, v in query:gmatch("&?([^=%?]+)=([^&%?]+)&?") do
                                if k and v then
                                        params[urldecode(k)] = urldecode(v);
                                end
                        end
                        return params;
                else
                        return urldecode(query);
                end
        end
end



local http_path = { http_base };
local function handle_request(method, body, request)
	local path = request.url.path:gsub("^/[^/]+/", "");
	
	local curr = control;
	
	for comp in path:gmatch("([^/]+)") do
		curr = curr[comp];
		if not curr then
			return response_404;
		end
	end
	
	if type(curr) == "table" then
		local s = {};
		for k,v in pairs(curr) do
			t_insert(s, tostring(k));
			t_insert(s, " = ");
			if type(v) == "function" then
				t_insert(s, "action")
			elseif type(v) == "table" then
				t_insert(s, "list");
			else
				t_insert(s, tostring(v));
			end
			t_insert(s, "\n");
		end
		return t_concat(s);
	elseif type(curr) == "function" then
		local params = query_to_table(request.url.query);
		params.host = request.headers.host:gsub(":%d+", "");
		local ok, ret1, ret2 = pcall(curr, params);
		if not ok then
			return "EPIC FAIL: "..tostring(ret1);
		elseif not ret1 then
			return "FAIL: "..tostring(ret2);
		else
			return "OK: "..tostring(ret2);
		end
	end
end

httpserver.new{ port = 5280, base = "control", handler = handle_request, ssl = false }