-- Prosody IM
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- This module allows you to use cqueues with a net.server mainloop
--

local server = require "net.server";
local cqueues = require "cqueues";
assert(cqueues.VERSION >= 20150113, "cqueues newer than 20150113 required")

-- Create a single top level cqueue
local cq;

if server.cq then -- server provides cqueues object
	cq = server.cq;
elseif server.watchfd then
	cq = cqueues.new();
	server.watchfd(cq:pollfd(), function ()
		assert(cq:loop(0));
	end);
else
	error "NYI"
end

return {
	cq = cq;
}
