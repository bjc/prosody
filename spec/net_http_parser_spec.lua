local http_parser = require "net.http.parser";

local function test_stream(stream, expect)
	local success_cb = spy.new(function (packet)
		assert.is_table(packet);
		if packet.body ~= false then
			assert.is_equal(expect.body, packet.body);
		end
	end);

	stream = stream:gsub("\n", "\r\n");
	local parser = http_parser.new(success_cb, error, stream:sub(1,4) == "HTTP" and "client" or "server")
	for chunk in stream:gmatch("..?.?") do
		parser:feed(chunk);
	end

	assert.spy(success_cb).was_called(expect.count or 1);
end


describe("net.http.parser", function()
	describe("parser", function()
		it("should handle requests with no content-length or body", function ()
			test_stream(
[[
GET / HTTP/1.1
Host: example.com

]],
				{
					body = "";
				}
			);
		end);

		it("should handle responses with empty body", function ()
			test_stream(
[[
HTTP/1.1 200 OK
Content-Length: 0

]],
				{
					body = "";
				}
			);
		end);

		it("should handle simple responses", function ()
			test_stream(

[[
HTTP/1.1 200 OK
Content-Length: 7

Hello
]],
				{
					body = "Hello\r\n", count = 1;
				}
			);
		end);

		it("should handle chunked encoding in responses", function ()
			test_stream(

[[
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


]],
				{
					body = "Hello", count = 2;
				}
			);
		end);

		it("should handle a stream of responses", function ()
			test_stream(

[[
HTTP/1.1 200 OK
Content-Length: 5

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


]],
				{
					body = "Hello", count = 3;
				}
			);
		end);
	end);
end);
