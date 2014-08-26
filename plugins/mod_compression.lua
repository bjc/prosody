-- Prosody IM
-- Copyright (C) 2009-2012 Tobias Markmann
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local zlib = require "zlib";
local pcall = pcall;
local tostring = tostring;

local xmlns_compression_feature = "http://jabber.org/features/compress"
local xmlns_compression_protocol = "http://jabber.org/protocol/compress"
local xmlns_stream = "http://etherx.jabber.org/streams";
local compression_stream_feature = st.stanza("compression", {xmlns=xmlns_compression_feature}):tag("method"):text("zlib"):up();
local add_filter = require "util.filters".add_filter;

local compression_level = module:get_option_number("compression_level", 7);

if not compression_level or compression_level < 1 or compression_level > 9 then
	module:log("warn", "Invalid compression level in config: %s", tostring(compression_level));
	module:log("warn", "Module loading aborted. Compression won't be available.");
	return;
end

module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.compressed and (origin.type == "c2s" or origin.type == "s2sin" or origin.type == "s2sout") then
		-- FIXME only advertise compression support when TLS layer has no compression enabled
		features:add_child(compression_stream_feature);
	end
end);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	-- FIXME only advertise compression support when TLS layer has no compression enabled
	if not origin.compressed and (origin.type == "c2s" or origin.type == "s2sin" or origin.type == "s2sout") then
		features:add_child(compression_stream_feature);
	end
end);

-- Hook to activate compression if remote server supports it.
module:hook_stanza(xmlns_stream, "features",
		function (session, stanza)
			if not session.compressed and (session.type == "c2s" or session.type == "s2sin" or session.type == "s2sout") then
				-- does remote server support compression?
				local comp_st = stanza:child_with_name("compression");
				if comp_st then
					-- do we support the mechanism
					for a in comp_st:children() do
						local algorithm = a[1]
						if algorithm == "zlib" then
							session.sends2s(st.stanza("compress", {xmlns=xmlns_compression_protocol}):tag("method"):text("zlib"))
							session.log("debug", "Enabled compression using zlib.")
							return true;
						end
					end
					session.log("debug", "Remote server supports no compression algorithm we support.")
				end
			end
		end
, 250);


-- returns either nil or a fully functional ready to use inflate stream
local function get_deflate_stream(session)
	local status, deflate_stream = pcall(zlib.deflate, compression_level);
	if status == false then
		local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed");
		(session.sends2s or session.send)(error_st);
		session.log("error", "Failed to create zlib.deflate filter.");
		module:log("error", "%s", tostring(deflate_stream));
		return
	end
	return deflate_stream
end

-- returns either nil or a fully functional ready to use inflate stream
local function get_inflate_stream(session)
	local status, inflate_stream = pcall(zlib.inflate);
	if status == false then
		local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed");
		(session.sends2s or session.send)(error_st);
		session.log("error", "Failed to create zlib.inflate filter.");
		module:log("error", "%s", tostring(inflate_stream));
		return
	end
	return inflate_stream
end

-- setup compression for a stream
local function setup_compression(session, deflate_stream)
	add_filter(session, "bytes/out", function(t)
		local status, compressed, eof = pcall(deflate_stream, tostring(t), 'sync');
		if status == false then
			module:log("warn", "%s", tostring(compressed));
			session:close({
				condition = "undefined-condition";
				text = compressed;
				extra = st.stanza("failure", {xmlns="http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			return;
		end
		return compressed;
	end);	
end

-- setup decompression for a stream
local function setup_decompression(session, inflate_stream)
	add_filter(session, "bytes/in", function(data)
		local status, decompressed, eof = pcall(inflate_stream, data);
		if status == false then
			module:log("warn", "%s", tostring(decompressed));
			session:close({
				condition = "undefined-condition";
				text = decompressed;
				extra = st.stanza("failure", {xmlns="http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			return;
		end
		return decompressed;
	end);
end

module:hook("stanza/http://jabber.org/protocol/compress:compressed", function(event)
	local session = event.origin;
	
	if session.type == "s2sout" then
		session.log("debug", "Activating compression...")
		-- create deflate and inflate streams
		local deflate_stream = get_deflate_stream(session);
		if not deflate_stream then return true; end
		
		local inflate_stream = get_inflate_stream(session);
		if not inflate_stream then return true; end
		
		-- setup compression for session.w
		setup_compression(session, deflate_stream);
			
		-- setup decompression for session.data
		setup_decompression(session, inflate_stream);
		session:reset_stream();
		session:open_stream(session.from_host, session.to_host);
		session.compressed = true;
		return true;
	end
end);

module:hook("stanza/http://jabber.org/protocol/compress:failure", function(event)
	local err = event.stanza:get_child();
	(event.origin.log or module._log)("warn", "Compression setup failed (%s)", err and err.name or "unknown reason");
	return true;
end);

module:hook("stanza/http://jabber.org/protocol/compress:compress", function(event)
	local session, stanza = event.origin, event.stanza;

	if session.type == "c2s" or session.type == "s2sin" then
		-- fail if we are already compressed
		if session.compressed then
			local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed");
			(session.sends2s or session.send)(error_st);
			session.log("debug", "Client tried to establish another compression layer.");
			return true;
		end
		
		-- checking if the compression method is supported
		local method = stanza:child_with_name("method");
		method = method and (method[1] or "");
		if method == "zlib" then
			session.log("debug", "zlib compression enabled.");
			
			-- create deflate and inflate streams
			local deflate_stream = get_deflate_stream(session);
			if not deflate_stream then return true; end
			
			local inflate_stream = get_inflate_stream(session);
			if not inflate_stream then return true; end
			
			(session.sends2s or session.send)(st.stanza("compressed", {xmlns=xmlns_compression_protocol}));
			session:reset_stream();
			
			-- setup compression for session.w
			setup_compression(session, deflate_stream);
				
			-- setup decompression for session.data
			setup_decompression(session, inflate_stream);
			
			session.compressed = true;
		elseif method then
			session.log("debug", "%s compression selected, but we don't support it.", tostring(method));
			local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("unsupported-method");
			(session.sends2s or session.send)(error_st);
		else
			(session.sends2s or session.send)(st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed"));
		end
		return true;
	end
end);

