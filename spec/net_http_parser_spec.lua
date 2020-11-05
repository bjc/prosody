local http_parser = require "net.http.parser";
local sha1 = require "util.hashes".sha1;

local parser_input_bytes = 3;

local function CRLF(s)
	return (s:gsub("\n", "\r\n"));
end

local function test_stream(stream, expect)
	local success_cb = spy.new(function (packet)
		assert.is_table(packet);
		if packet.body ~= false then
			assert.is_equal(expect.body, packet.body);
		end
	end);

	local parser = http_parser.new(success_cb, error, stream:sub(1,4) == "HTTP" and "client" or "server")
	for chunk in stream:gmatch("."..string.rep(".?", parser_input_bytes-1)) do
		parser:feed(chunk);
	end

	assert.spy(success_cb).was_called(expect.count or 1);
end


describe("net.http.parser", function()
	describe("parser", function()
		it("should handle requests with no content-length or body", function ()
			test_stream(
CRLF[[
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
CRLF[[
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

CRLF[[
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

CRLF[[
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

CRLF[[
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

	it("should handle large chunked responses", function ()
		local data = io.open("spec/inputs/http/httpstream-chunked-test.txt", "rb"):read("*a");

		-- Just a sanity check... text editors and things may mess with line endings, etc.
		assert.equal("25930f021785ae14053a322c2dbc1897c3769720", sha1(data, true), "test data malformed");

		test_stream(data, {
			body = string.rep("~", 11085), count = 2;
		});
	end);
end);
