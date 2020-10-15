describe("net.websocket.frames", function ()
	local nwf = require "net.websocket.frames";

	local test_frames = {
		simple_empty = {
			["opcode"] = 0;
			["length"] = 0;
			["data"] = "";
			["FIN"] = false;
			["MASK"] = false;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		simple_data = {
			["opcode"] = 0;
			["length"] = 5;
			["data"] = "hello";
			["FIN"] = false;
			["MASK"] = false;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		simple_fin = {
			["opcode"] = 0;
			["length"] = 0;
			["data"] = "";
			["FIN"] = true;
			["MASK"] = false;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		with_mask = {
			["opcode"] = 0;
			["length"] = 5;
			["data"] = "hello";
			["key"] = " \0 \0";
			["FIN"] = true;
			["MASK"] = true;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		empty_with_mask = {
			["opcode"] = 0;
			["key"] = " \0 \0";
			["FIN"] = true;
			["MASK"] = true;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		ping = {
			["opcode"] = 0x9;
			["length"] = 4;
			["data"] = "ping";
			["FIN"] = true;
			["MASK"] = false;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
		pong = {
			["opcode"] = 0xa;
			["length"] = 4;
			["data"] = "pong";
			["FIN"] = true;
			["MASK"] = false;
			["RSV1"] = false;
			["RSV2"] = false;
			["RSV3"] = false;
		};
	}

	describe("build", function ()
		local build = nwf.build;
		it("works", function ()
			assert.equal("\0\0", build(test_frames.simple_empty));
			assert.equal("\0\5hello", build(test_frames.simple_data));
			assert.equal("\128\0", build(test_frames.simple_fin));
			assert.equal("\128\133 \0 \0HeLlO", build(test_frames.with_mask))
			assert.equal("\128\128 \0 \0", build(test_frames.empty_with_mask))
			assert.equal("\137\4ping", build(test_frames.ping));
			assert.equal("\138\4pong", build(test_frames.pong));
		end);
	end);

	describe("parse", function ()
		local parse = nwf.parse;
		it("works", function ()
			assert.same(test_frames.simple_empty, parse("\0\0"));
			assert.same(test_frames.simple_data, parse("\0\5hello"));
			assert.same(test_frames.simple_fin, parse("\128\0"));
			assert.same(test_frames.with_mask, parse("\128\133 \0 \0HeLlO"));
			assert.same(test_frames.ping, parse("\137\4ping"));
			assert.same(test_frames.pong, parse("\138\4pong"));
		end);
	end);

end);

