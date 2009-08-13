-- Prosody IM
-- Copyright (C) 2009 Tobias Markmann
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local zlib = require "zlib";
local print = print

local xmlns_compression_feature = "http://jabber.org/features/compress"
local xmlns_compression_protocol = "http://jabber.org/protocol/compress"
local compression_stream_feature = st.stanza("compression", {xmlns=xmlns_compression_feature}):tag("method"):text("zlib"):up();

local compression_level = module:get_option("compression_level");

-- if not defined assume admin wants best compression
if compression_level == nil then compression_level = 9 end;

compression_level = tonumber(compression_level);
if not compression_level or compression_level < 1 or compression_level > 9 then
	module:log("warn", "Invalid compression level in config: %s", tostring(compression_level));
	module:log("warn", "Module loading aborted. Compression won't be available.");
	return;
end

module:add_event_hook("stream-features",
		function (session, features)
			if not session.compressed then
				-- FIXME only advertise compression support when TLS layer has no compression enabled
				features:add_child(compression_stream_feature);
			end
		end
);

-- TODO Support compression on S2S level too.
module:add_handler("c2s_unauthed", "compress", xmlns_compression_protocol,
		function(session, stanza)
			-- checking if the compression method is supported
			local method = stanza:child_with_name("method")[1];
			if method == "zlib" then
				session.log("info", method.." compression selected.");
				session.send(st.stanza("compressed", {xmlns=xmlns_compression_protocol}));
				session:reset_stream();
				
				-- create deflate and inflate streams
				local deflate_stream = zlib.deflate(compression_level);
				local inflate_stream = zlib.inflate();
				
				-- setup compression for session.w
				local old_send = session.send;
				
				session.send = function(t)
						local compressed, eof = deflate_stream(tostring(t), 'sync');
						old_send(compressed);
					end;
					
				-- setup decompression for session.data
				local function setup_decompression(session)
					local old_data = session.data
					session.data = function(conn, data)
							local decompressed, eof = inflate_stream(data);
							old_data(conn, decompressed);
						end;
				end
				setup_decompression(session);
				
				local session_reset_stream = session.reset_stream;
				session.reset_stream = function(session)
						session_reset_stream(session);
						setup_decompression(session);
						return true;
					end;
				session.compressed = true;
			else
				session.log("info", method.." compression selected. But we don't support it.");
				local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("unsupported-method");
				session.send(error_st);
			end
		end
);
