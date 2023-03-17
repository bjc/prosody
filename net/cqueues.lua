-- Prosody IM
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- This module allows you to use cqueues with a net.server mainloop
--

local server = require "prosody.net.server";
local cqueues = require "cqueues";
local timer = require "prosody.util.timer";
assert(cqueues.VERSION >= 20150113, "cqueues newer than 20150113 required")

-- Create a single top level cqueue
local cq;

if server.cq then -- server provides cqueues object
	cq = server.cq;
elseif server.watchfd then
	cq = cqueues.new();
	local timeout = timer.add_task(cq:timeout() or 0, function ()
		-- FIXME It should be enough to reschedule this timeout instead of replacing it, but this does not work.  See https://issues.prosody.im/1572
		assert(cq:loop(0));
		return cq:timeout();
	end);
	server.watchfd(cq:pollfd(), function ()
		assert(cq:loop(0));
		local t = cq:timeout();
		if t then
			timer.stop(timeout);
			timeout = timer.add_task(cq:timeout(), function ()
				assert(cq:loop(0));
				return cq:timeout();
			end);
		end
	end);
else
	error "NYI"
end

return {
	cq = cq;
}
