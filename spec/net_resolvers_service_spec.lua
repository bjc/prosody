local set = require "util.set";

insulate("net.resolvers.service", function ()
	local adns = {
		resolver = function ()
			return {
				lookup = function (_, cb, qname, qtype, qclass)
					if qname == "_xmpp-server._tcp.example.com"
					   and (qtype or "SRV") == "SRV"
					   and (qclass or "IN") == "IN" then
						cb({
							{ -- 60+35+60
								srv = { target = "xmpp0-a.example.com", port = 5228, priority = 0, weight = 60 };
							};
							{
								srv = { target = "xmpp0-b.example.com", port = 5216, priority = 0, weight = 35 };
							};
							{
								srv = { target = "xmpp0-c.example.com", port = 5200, priority = 0, weight = 0 };
							};
							{
								srv = { target = "xmpp0-d.example.com", port = 5256, priority = 0, weight = 120 };
							};

							{
								srv = { target = "xmpp1-a.example.com", port = 5273, priority = 1, weight = 30 };
							};
							{
								srv = { target = "xmpp1-b.example.com", port = 5274, priority = 1, weight = 30 };
							};

							{
								srv = { target = "xmpp2.example.com", port = 5275, priority = 2, weight = 0 };
							};
						});
					elseif qname == "_xmpp-server._tcp.single.example.com"
					   and (qtype or "SRV") == "SRV"
					   and (qclass or "IN") == "IN" then
						cb({
							{
								srv = { target = "xmpp0-a.example.com", port = 5269, priority = 0, weight = 0 };
							};
						});
					elseif qname == "_xmpp-server._tcp.half.example.com"
					   and (qtype or "SRV") == "SRV"
					   and (qclass or "IN") == "IN" then
						cb({
							{
								srv = { target = "xmpp0-a.example.com", port = 5269, priority = 0, weight = 0 };
							};
							{
								srv = { target = "xmpp0-b.example.com", port = 5270, priority = 0, weight = 1 };
							};
						});
					elseif qtype == "A" then
						local l = qname:match("%-(%a)%.example.com$") or "1";
						local d = ("%d"):format(l:byte())
						cb({
							{
								a = "127.0.0."..d;
							};
						});
					elseif qtype == "AAAA" then
						local l = qname:match("%-(%a)%.example.com$") or "1";
						local d = ("%04d"):format(l:byte())
						cb({
							{
								aaaa = "fdeb:9619:649e:c7d9::"..d;
							};
						});
					else
						cb(nil);
					end
				end;
			};
		end;
	};
	package.loaded["net.adns"] = mock(adns);
	local resolver = require "net.resolvers.service";
	math.randomseed(os.time());
	it("works for 99% of deployments", function ()
		-- Most deployments only have a single SRV record, let's make
		-- sure that works okay

		local expected_targets = set.new({
			-- xmpp0-a
			"tcp4  127.0.0.97  5269";
			"tcp6  fdeb:9619:649e:c7d9::0097  5269";
		});
		local received_targets = set.new({});

		local r = resolver.new("single.example.com", "xmpp-server");
		local done = false;
		local function handle_target(...)
			if ... == nil then
				done = true;
				-- No more targets
				return;
			end
			received_targets:add(table.concat({ ... }, "  ", 1, 3));
		end
		r:next(handle_target);
		while not done do
			r:next(handle_target);
		end

		-- We should have received all expected targets, and no unexpected
		-- ones:
		assert.truthy(set.xor(received_targets, expected_targets):empty());
	end);

	it("supports A/AAAA fallback", function ()
		-- Many deployments don't have any SRV records, so we should
		-- fall back to A/AAAA records instead when that is the case

		local expected_targets = set.new({
			-- xmpp0-a
			"tcp4  127.0.0.97  5269";
			"tcp6  fdeb:9619:649e:c7d9::0097  5269";
		});
		local received_targets = set.new({});

		local r = resolver.new("xmpp0-a.example.com", "xmpp-server", "tcp", { default_port = 5269 });
		local done = false;
		local function handle_target(...)
			if ... == nil then
				done = true;
				-- No more targets
				return;
			end
			received_targets:add(table.concat({ ... }, "  ", 1, 3));
		end
		r:next(handle_target);
		while not done do
			r:next(handle_target);
		end

		-- We should have received all expected targets, and no unexpected
		-- ones:
		assert.truthy(set.xor(received_targets, expected_targets):empty());
	end);


	it("works", function ()
		local expected_targets = set.new({
			-- xmpp0-a
			"tcp4  127.0.0.97  5228";
			"tcp6  fdeb:9619:649e:c7d9::0097  5228";
			"tcp4  127.0.0.97  5273";
			"tcp6  fdeb:9619:649e:c7d9::0097  5273";

			-- xmpp0-b
			"tcp4  127.0.0.98  5274";
			"tcp6  fdeb:9619:649e:c7d9::0098  5274";
			"tcp4  127.0.0.98  5216";
			"tcp6  fdeb:9619:649e:c7d9::0098  5216";

			-- xmpp0-c
			"tcp4  127.0.0.99  5200";
			"tcp6  fdeb:9619:649e:c7d9::0099  5200";

			-- xmpp0-d
			"tcp4  127.0.0.100  5256";
			"tcp6  fdeb:9619:649e:c7d9::0100  5256";

			-- xmpp2
			"tcp4  127.0.0.49  5275";
			"tcp6  fdeb:9619:649e:c7d9::0049  5275";

		});
		local received_targets = set.new({});

		local r = resolver.new("example.com", "xmpp-server");
		local done = false;
		local function handle_target(...)
			if ... == nil then
				done = true;
				-- No more targets
				return;
			end
			received_targets:add(table.concat({ ... }, "  ", 1, 3));
		end
		r:next(handle_target);
		while not done do
			r:next(handle_target);
		end

		-- We should have received all expected targets, and no unexpected
		-- ones:
		assert.truthy(set.xor(received_targets, expected_targets):empty());
	end);

	it("balances across weights correctly #slow", function ()
		-- This mimics many repeated connections to 'example.com' (mock
		-- records defined above), and records the port number of the
		-- first target. Therefore it (should) only return priority
		-- 0 records, and the input data is constructed such that the
		-- last two digits of the port number represent the percentage
		-- of times that record should (on average) be picked first.

		-- To prevent random test failures, we test across a handful
		-- of fixed (randomly selected) seeds.
		for _, seed in ipairs({ 8401877, 3943829, 7830992 }) do
			math.randomseed(seed);

			local results = {};
			local function run()
				local run_results = {};
				local r = resolver.new("example.com", "xmpp-server");
				local function record_target(...)
					if ... == nil then
						-- No more targets
						return;
					end
					run_results = { ... };
				end
				r:next(record_target);
				return run_results[3];
			end

			for _ = 1, 1000 do
				local port = run();
				results[port] = (results[port] or 0) + 1;
			end

			local ports = {};
			for port in pairs(results) do
				table.insert(ports, port);
			end
			table.sort(ports);
			for _, port in ipairs(ports) do
				--print("PORT", port, tostring((results[port]/1000) * 100).."% hits (expected "..tostring(port-5200).."%)");
				local hit_pct = (results[port]/1000) * 100;
				local expected_pct = port - 5200;
				--print(hit_pct, expected_pct, math.abs(hit_pct - expected_pct));
				assert.is_true(math.abs(hit_pct - expected_pct) < 5);
			end
			--print("---");
		end
	end);
end);
