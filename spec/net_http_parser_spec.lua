local http_parser = require "net.http.parser";
local sha1 = require "util.hashes".sha1;

local parser_input_bytes = 3;

local function CRLF(s)
	return (s:gsub("\n", "\r\n"));
end

local function test_stream(stream, expect)
	local chunks_processed = 0;
	local success_cb = spy.new(function (packet)
		assert.is_table(packet);
		if packet.body ~= false then
			assert.is_equal(expect.body, packet.body);
		end
		if expect.chunks then
			if chunks_processed == 0 then
				assert.is_true(packet.partial);
				packet.body_sink = {
					write = function (_, data)
						chunks_processed = chunks_processed + 1;
						assert.equal(expect.chunks[chunks_processed], data);
						return true;
					end;
				};
			end
		end
	end);

	local function options_cb()
		return {
			-- Force streaming API mode
			body_size_limit = expect.chunks and 0 or nil;
			buffer_size_limit = 10*1024*2;
		};
	end

	local parser = http_parser.new(success_cb, error, (stream[1] or stream):sub(1,4) == "HTTP" and "client" or "server", options_cb)
	if type(stream) == "string" then
		for chunk in stream:gmatch("."..string.rep(".?", parser_input_bytes-1)) do
			parser:feed(chunk);
		end
	else
		for _, chunk in ipairs(stream) do
			parser:feed(chunk);
		end
	end

	if expect.chunks then
		assert.equal(chunks_processed, #expect.chunks);
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
					body = "Hello", count = 3;
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
					body = "Hello", count = 4;
				}
			);
		end);

		it("should correctly find chunk boundaries", function ()
			test_stream({

CRLF[[
HTTP/1.1 200 OK
Transfer-Encoding: chunked

]].."3\r\n:)\n\r\n"},
				{
					count = 1; -- Once (partial)
					chunks = {
						":)\n"
					};
				}
			);
		end);

		it("should reject very large request heads", function()
			local finished = false;
			local success_cb = spy.new(function()
				finished = true;
			end)
			local error_cb = spy.new(function()
				finished = true;
			end)
			local parser = http_parser.new(success_cb, error_cb, "server", function()
				return { head_size_limit = 1024; body_size_limit = 1024; buffer_size_limit = 2048 };
			end)
			parser:feed("GET / HTTP/1.1\r\n");
			for i = 1, 64 do -- * header line > buffer_size_limit
				parser:feed(string.format("Header-%04d: Yet-AnotherValue\r\n", i));
				if finished then
					-- should hit an error around half-way
					break
				end
			end
			if not finished then
				parser:feed("\r\n")
			end
			assert.spy(success_cb).was_called(0);
			assert.spy(error_cb).was_called(1);
			assert.spy(error_cb).was_called_with("header-too-large");
		end)
	end);

	it("should handle large chunked responses", function ()
		local data = io.open("spec/inputs/http/httpstream-chunked-test.txt", "rb"):read("*a");

		-- Just a sanity check... text editors and things may mess with line endings, etc.
		assert.equal("25930f021785ae14053a322c2dbc1897c3769720", sha1(data, true), "test data malformed");

		test_stream(data, {
			body = string.rep("~", 11085), count = 3;
		});
	end);
end);
