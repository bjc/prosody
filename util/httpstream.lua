
local coroutine = coroutine;
local tonumber = tonumber;

local deadroutine = coroutine.create(function() end);
coroutine.resume(deadroutine);

module("httpstream")

local function parser(success_cb, parser_type, options_cb)
	local data = coroutine.yield();
	local function readline()
		local pos = data:find("\r\n", nil, true);
		while not pos do
			data = data..coroutine.yield();
			pos = data:find("\r\n", nil, true);
		end
		local r = data:sub(1, pos-1);
		data = data:sub(pos+2);
		return r;
	end
	local function readlength(n)
		while #data < n do
			data = data..coroutine.yield();
		end
		local r = data:sub(1, n);
		data = data:sub(n + 1);
		return r;
	end
	local function readheaders()
		local headers = {}; -- read headers
		while true do
			local line = readline();
			if line == "" then break; end -- headers done
			local key, val = line:match("^([^%s:]+): *(.*)$");
			if not key then coroutine.yield("invalid-header-line"); end -- TODO handle multi-line and invalid headers
			key = key:lower();
			headers[key] = headers[key] and headers[key]..","..val or val;
		end
		return headers;
	end
	
	if not parser_type or parser_type == "server" then
		while true do
			-- read status line
			local status_line = readline();
			local method, path, httpversion = status_line:match("^(%S+)%s+(%S+)%s+HTTP/(%S+)$");
			if not method then coroutine.yield("invalid-status-line"); end
			path = path:gsub("^//+", "/"); -- TODO parse url more
			local headers = readheaders();
			
			-- read body
			local len = tonumber(headers["content-length"]);
			len = len or 0; -- TODO check for invalid len
			local body = readlength(len);
			
			success_cb({
				method = method;
				path = path;
				httpversion = httpversion;
				headers = headers;
				body = body;
			});
		end
	elseif parser_type == "client" then
		while true do
			-- read status line
			local status_line = readline();
			local httpversion, status_code, reason_phrase = status_line:match("^HTTP/(%S+)%s+(%d%d%d)%s+(.*)$");
			status_code = tonumber(status_code);
			if not status_code then coroutine.yield("invalid-status-line"); end
			local headers = readheaders();
			
			-- read body
			local have_body = not
				 ( (options_cb and options_cb().method == "HEAD")
				or (status_code == 204 or status_code == 304 or status_code == 301)
				or (status_code >= 100 and status_code < 200) );
			
			local body;
			if have_body then
				local len = tonumber(headers["content-length"]);
				if headers["transfer-encoding"] == "chunked" then
					body = "";
					while true do
						local chunk_size = readline():match("^%x+");
						if not chunk_size then coroutine.yield("invalid-chunk-size"); end
						chunk_size = tonumber(chunk_size, 16)
						if chunk_size == 0 then break; end
						body = body..readlength(chunk_size);
						if readline() ~= "" then coroutine.yield("invalid-chunk-ending"); end
					end
					local trailers = readheaders();
				elseif len then -- TODO check for invalid len
					body = readlength(len);
				else -- read to end
					repeat
						local newdata = coroutine.yield();
						data = data..newdata;
					until newdata == "";
					body, data = data, "";
				end
			end
			
			success_cb({
				code = status_code;
				httpversion = httpversion;
				headers = headers;
				body = body;
				-- COMPAT the properties below are deprecated
				responseversion = httpversion;
				responseheaders = headers;
			});
		end
	else coroutine.yield("unknown-parser-type"); end
end

function new(success_cb, error_cb, parser_type, options_cb)
	local co = coroutine.create(parser);
	coroutine.resume(co, success_cb, parser_type, options_cb)
	return {
		feed = function(self, data)
			if not data then
				if parser_type == "client" then coroutine.resume(co, ""); end
				co = deadroutine;
				return error_cb();
			end
			local success, result = coroutine.resume(co, data);
			if result then
				co = deadroutine;
				return error_cb(result);
			end
		end;
	};
end

return _M;
