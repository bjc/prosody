local tonumber = tonumber;
local assert = assert;
local url_parse = require "socket.url".parse;
local urldecode = require "util.http".urldecode;
local dbuffer = require "util.dbuffer";

local function preprocess_path(path)
	path = urldecode((path:gsub("//+", "/")));
	if path:sub(1,1) ~= "/" then
		path = "/"..path;
	end
	local level = 0;
	for component in path:gmatch("([^/]+)/") do
		if component == ".." then
			level = level - 1;
		elseif component ~= "." then
			level = level + 1;
		end
		if level < 0 then
			return nil;
		end
	end
	return path;
end

local httpstream = {};

function httpstream.new(success_cb, error_cb, parser_type, options_cb)
	local client = true;
	if not parser_type or parser_type == "server" then client = false; else assert(parser_type == "client", "Invalid parser type"); end
	local bodylimit = tonumber(options_cb and options_cb().body_size_limit) or 10*1024*1024;
	-- https://stackoverflow.com/a/686243
	-- Indiviual headers can be up to 16k? What madness?
	local headlimit = tonumber(options_cb and options_cb().head_size_limit) or 10*1024;
	local buflimit = tonumber(options_cb and options_cb().buffer_size_limit) or bodylimit * 2;
	local buffer = dbuffer.new(buflimit);
	local chunked;
	local state = nil;
	local packet;
	local len;
	local have_body;
	local error;
	return {
		feed = function(_, data)
			if error then return nil, "parse has failed"; end
			if not data then -- EOF
				if state and client and not len then -- reading client body until EOF
					buffer:collapse();
					packet.body = buffer:read_chunk() or "";
					success_cb(packet);
					state = nil;
				elseif buffer:length() ~= 0 then -- unexpected EOF
					error = true; return error_cb("unexpected-eof");
				end
				return;
			end
			if not buffer:write(data) then error = true; return error_cb("max-buffer-size-exceeded"); end
			while buffer:length() > 0 do
				if state == nil then -- read request
					local index = buffer:sub(1, headlimit):find("\r\n\r\n", nil, true);
					if not index then return; end -- not enough data
					-- FIXME was reason_phrase meant to be passed on somewhere?
					local method, path, httpversion, status_code, reason_phrase; -- luacheck: ignore reason_phrase
					local first_line;
					local headers = {};
					for line in buffer:read(index+3):gmatch("([^\r\n]+)\r\n") do -- parse request
						if first_line then
							local key, val = line:match("^([^%s:]+): *(.*)$");
							if not key then error = true; return error_cb("invalid-header-line"); end -- TODO handle multi-line and invalid headers
							key = key:lower();
							headers[key] = headers[key] and headers[key]..","..val or val;
						else
							first_line = line;
							if client then
								httpversion, status_code, reason_phrase = line:match("^HTTP/(1%.[01]) (%d%d%d) (.*)$");
								status_code = tonumber(status_code);
								if not status_code then error = true; return error_cb("invalid-status-line"); end
								have_body = not
									 ( (options_cb and options_cb().method == "HEAD")
									or (status_code == 204 or status_code == 304 or status_code == 301)
									or (status_code >= 100 and status_code < 200) );
							else
								method, path, httpversion = line:match("^(%w+) (%S+) HTTP/(1%.[01])$");
								if not method then error = true; return error_cb("invalid-status-line"); end
							end
						end
					end
					if not first_line then error = true; return error_cb("invalid-status-line"); end
					chunked = have_body and headers["transfer-encoding"] == "chunked";
					len = tonumber(headers["content-length"]); -- TODO check for invalid len
					if len and len > bodylimit then error = true; return error_cb("content-length-limit-exceeded"); end
					-- TODO ask a callback whether to proceed in case of large requests or Expect: 100-continue
					if client then
						-- FIXME handle '100 Continue' response (by skipping it)
						if not have_body then len = 0; end
						packet = {
							code = status_code;
							httpversion = httpversion;
							headers = headers;
							body = false;
							-- COMPAT the properties below are deprecated
							responseversion = httpversion;
							responseheaders = headers;
						};
					else
						local parsed_url;
						if path:byte() == 47 then -- starts with /
							local _path, _query = path:match("([^?]*).?(.*)");
							if _query == "" then _query = nil; end
							parsed_url = { path = _path, query = _query };
						else
							parsed_url = url_parse(path);
							if not(parsed_url and parsed_url.path) then error = true; return error_cb("invalid-url"); end
						end
						path = preprocess_path(parsed_url.path);
						headers.host = parsed_url.host or headers.host;

						len = len or 0;
						packet = {
							method = method;
							url = parsed_url;
							path = path;
							httpversion = httpversion;
							headers = headers;
							body = false;
							body_sink = nil;
						};
					end
					if chunked then
						packet.body_buffer = dbuffer.new(buflimit);
					end
					state = true;
				end
				if state then -- read body
					if chunked then
						local chunk_header = buffer:sub(1, 512); -- XXX How large do chunk headers grow?
						local chunk_size, chunk_start = chunk_header:match("^(%x+)[^\r\n]*\r\n()");
						if not chunk_size then return; end
						chunk_size = chunk_size and tonumber(chunk_size, 16);
						if not chunk_size then error = true; return error_cb("invalid-chunk-size"); end
						if chunk_size == 0 and chunk_header:find("\r\n\r\n", chunk_start-2, true) then
							local body_buffer = packet.body_buffer;
							if body_buffer then
								packet.body_buffer = nil;
								body_buffer:collapse();
								packet.body = body_buffer:read_chunk() or "";
							end

							buffer:collapse();
							local buf = buffer:read_chunk();
							buf = buf:gsub("^.-\r\n\r\n", ""); -- This ensure extensions and trailers are stripped
							buffer:write(buf);
							state, chunked = nil, nil;
							success_cb(packet);
						elseif buffer:length() - chunk_start - 2 >= chunk_size then -- we have a chunk
							buffer:discard(chunk_start - 1); -- TODO verify that it's not off-by-one
							packet.body_buffer:write(buffer:read(chunk_size));
							buffer:discard(2); -- CRLF
						else -- Partial chunk remaining
							break;
						end
					elseif buffer:length() >= len then
						assert(not chunked)
						packet.body = buffer:read(len) or "";
						state = nil; success_cb(packet);
					else
						break;
					end
				else
					break;
				end
			end
		end;
	};
end

return httpstream;
