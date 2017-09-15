local httpstreams = { [[
GET / HTTP/1.1
Host: example.com

]], [[
HTTP/1.1 200 OK
Content-Length: 0

]], [[
HTTP/1.1 200 OK
Content-Length: 7

Hello
HTTP/1.1 200 OK
Transfer-Encoding: chunked

1
H
1
e
2
ll
1
o
0


]]
}


local http_parser = require "net.http.parser";

describe("net.http.parser", function()
	describe("#new()", function()
		it("should work", function()
			for _, stream in ipairs(httpstreams) do
				local success;
				local function success_cb(packet)
					success = true;
				end
				stream = stream:gsub("\n", "\r\n");
				local parser = http_parser.new(success_cb, error, stream:sub(1,4) == "HTTP" and "client" or "server")
				for chunk in stream:gmatch("..?.?") do
					parser:feed(chunk);
				end

				assert.is_true(success);
			end
		end);
	end);
end);
