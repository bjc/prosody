-- Prosody IM
-- Copyright (C) 2009 Tobias Markmann
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local print = print

local xmlns_compression_feature = "http://jabber.org/features/compress"
local xmlns_compression_protocol = "http://jabber.org/protocol/compress"
local compression_stream_feature = st.stanza("compression", {xmlns=xmlns_compression_feature}):tag("method"):text("zlib"):up();


module:add_event_hook("stream-features",
		function (session, features)
			features:add_child(compression_stream_feature);
		end
);

module:add_handler("c2s_unauthed", "compress", xmlns_compression_protocol,
		function(session, stanza)
			-- checking if the compression method is supported
			local method = stanza:child_with_name("method")[1];
			if method == "zlib" then
				session.log("info", method.." compression selected.");
				session.send(st.stanza("compressed", {xmlns=xmlns_compression_protocol}));
			else
				session.log("info", method.." compression selected. But we don't support it.");
				local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("unsupported-method");
				session.send(error_st);
			end
		end
);
