-- Prosody IM
-- Copyright (C) 2009 Tobias Markmann
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

local compression_level = module:get_option("compression_level");
-- if not defined assume admin wants best compression
if compression_level == nil then compression_level = 9 end;


compression_level = tonumber(compression_level);
if not compression_level or compression_level < 1 or compression_level > 9 then
	module:log("warn", "Invalid compression level in config: %s", tostring(compression_level));
	module:log("warn", "Module loading aborted. Compression won't be available.");
	return;
end

module:hook("stream-features", function(event)
	local origin, features = event.origin, event.features;
	if not origin.compressed then
		-- FIXME only advertise compression support when TLS layer has no compression enabled
		features:add_child(compression_stream_feature);
	end
end);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	-- FIXME only advertise compression support when TLS layer has no compression enabled
	if not origin.compressed then 
		features:add_child(compression_stream_feature);
	end
end);

-- Hook to activate compression if remote server supports it.
module:hook_stanza(xmlns_stream, "features",
		function (session, stanza)
			if not session.compressed then
				-- does remote server support compression?
				local comp_st = stanza:child_with_name("compression");
				if comp_st then
					-- do we support the mechanism
					for a in comp_st:children() do
						local algorithm = a[1]
						if algorithm == "zlib" then
							session.sends2s(st.stanza("compress", {xmlns=xmlns_compression_protocol}):tag("method"):text("zlib"))
							session.log("info", "Enabled compression using zlib.")
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
			session:close({
				condition = "undefined-condition";
				text = compressed;
				extra = st.stanza("failure", {xmlns="http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			module:log("warn", "%s", tostring(compressed));
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
			session:close({
				condition = "undefined-condition";
				text = decompressed;
				extra = st.stanza("failure", {xmlns="http://jabber.org/protocol/compress"}):tag("processing-failed");
			});
			module:log("warn", "%s", tostring(decompressed));
			return;
		end
		return decompressed;
	end);
end

module:add_handler({"s2sout_unauthed", "s2sout"}, "compressed", xmlns_compression_protocol, 
		function(session ,stanza)
			session.log("debug", "Activating compression...")
			-- create deflate and inflate streams
			local deflate_stream = get_deflate_stream(session);
			if not deflate_stream then return end
			
			local inflate_stream = get_inflate_stream(session);
			if not inflate_stream then return end
			
			-- setup compression for session.w
			setup_compression(session, deflate_stream);
				
			-- setup decompression for session.data
			setup_decompression(session, inflate_stream);
			local session_reset_stream = session.reset_stream;
			session.reset_stream = function(session)
					session_reset_stream(session);
					setup_decompression(session, inflate_stream);
					return true;
				end;
			session:reset_stream();
			local default_stream_attr = {xmlns = "jabber:server", ["xmlns:stream"] = "http://etherx.jabber.org/streams",
										["xmlns:db"] = 'jabber:server:dialback', version = "1.0", to = session.to_host, from = session.from_host};
			session.sends2s("<?xml version='1.0'?>");
			session.sends2s(st.stanza("stream:stream", default_stream_attr):top_tag());
			session.compressed = true;
		end
);

module:add_handler({"c2s_unauthed", "c2s", "s2sin_unauthed", "s2sin"}, "compress", xmlns_compression_protocol,
		function(session, stanza)
			-- fail if we are already compressed
			if session.compressed then
				local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed");
				(session.sends2s or session.send)(error_st);
				session.log("debug", "Client tried to establish another compression layer.");
				return;
			end
			
			-- checking if the compression method is supported
			local method = stanza:child_with_name("method");
			method = method and (method[1] or "");
			if method == "zlib" then
				session.log("debug", "zlib compression enabled.");
				
				-- create deflate and inflate streams
				local deflate_stream = get_deflate_stream(session);
				if not deflate_stream then return end
				
				local inflate_stream = get_inflate_stream(session);
				if not inflate_stream then return end
				
				(session.sends2s or session.send)(st.stanza("compressed", {xmlns=xmlns_compression_protocol}));
				session:reset_stream();
				
				-- setup compression for session.w
				setup_compression(session, deflate_stream);
					
				-- setup decompression for session.data
				setup_decompression(session, inflate_stream);
				
				local session_reset_stream = session.reset_stream;
				session.reset_stream = function(session)
						session_reset_stream(session);
						setup_decompression(session, inflate_stream);
						return true;
					end;
				session.compressed = true;
			elseif method then
				session.log("debug", "%s compression selected, but we don't support it.", tostring(method));
				local error_st = st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("unsupported-method");
				(session.sends2s or session.send)(error_st);
			else
				(session.sends2s or session.send)(st.stanza("failure", {xmlns=xmlns_compression_protocol}):tag("setup-failed"));
			end
		end
);

