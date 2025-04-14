local unpack = table.unpack;

local st = require "prosody.util.stanza";

local function mock_prosody()
	_G.prosody = {
		core_post_stanza = function () end;
		events = require "prosody.util.events".new();
		hosts = {};
		paths = {
			data = "./data";
		};
	};
end

local configs = {
	memory = {
		storage = "memory";
	};
	internal = {
		storage = "internal";
	};
	sqlite = {
		storage = "sql";
		sql = { driver = "SQLite3", database = "prosody-tests.sqlite" };
	};
	mysql = {
		storage = "sql";
		sql = { driver = "MySQL",  database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
	postgres = {
		storage = "sql";
		sql = { driver = "PostgreSQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
};

local test_only_driver = os.getenv "PROSODY_TEST_ONLY_STORAGE";
if test_only_driver then
	configs = { [test_only_driver] = configs[test_only_driver] }
end

local test_host = "storage-unit-tests.invalid";

describe("storagemanager", function ()
	for backend, backend_config in pairs(configs) do
		local tagged_name = "#"..backend;
		if backend ~= backend_config.storage then
			tagged_name = tagged_name.." #"..backend_config.storage;
		end
		insulate(tagged_name.." #storage backend", function ()
			mock_prosody();

			local config = require "prosody.core.configmanager";
			local sm = require "prosody.core.storagemanager";
			local hm = require "prosody.core.hostmanager";
			local mm = require "prosody.core.modulemanager";

			-- Simple check to ensure insulation is working correctly
			assert.is_nil(config.get(test_host, "storage"));

			for k, v in pairs(backend_config) do
				config.set(test_host, k, v);
			end
			assert(hm.activate(test_host, {}));
			sm.initialize_host(test_host);
			mm.load(test_host, "storage_"..backend_config.storage);

			describe("key-value stores", function ()
				-- These tests rely on being executed in order, disable any order
				-- randomization for this block
				randomize(false);

				local store;
				it("may be opened", function ()
					store = assert(sm.open(test_host, "test"));
				end);

				local simple_data = { foo = "bar" };

				it("may set data for a user", function ()
					assert(store:set("user9999", simple_data));
				end);

				it("may get data for a user", function ()
					assert.same(simple_data, assert(store:get("user9999")));
				end);

				it("may remove data for a user", function ()
					assert(store:set("user9999", nil));
					local ret, err = store:get("user9999");
					assert.is_nil(ret);
					assert.is_nil(err);
				end);
			end);

			describe("map stores", function ()
				-- These tests rely on being executed in order, disable any order
				-- randomization for this block
				randomize(false);

				local store, kv_store;
				it("may be opened", function ()
					store = assert(sm.open(test_host, "test-map", "map"));
				end);

				it("may be opened as a keyval store", function ()
					kv_store = assert(sm.open(test_host, "test-map", "keyval"));
				end);

				it("may set a specific key for a user", function ()
					assert(store:set("user9999", "foo", "bar"));
					assert.same(kv_store:get("user9999"), { foo = "bar" });
				end);

				it("may get a specific key for a user", function ()
					assert.equal("bar", store:get("user9999", "foo"));
				end);

				it("may find all users with a specific key", function ()
					assert.is_function(store.get_all);
					assert(store:set("user9999b", "bar", "bar"));
					assert(store:set("user9999c", "foo", "blah"));
					local ret, err = store:get_all("foo");
					assert.is_nil(err);
					assert.same({ user9999 = "bar", user9999c = "blah" }, ret);
				end);

				it("rejects empty or non-string keys to get_all", function ()
					assert.is_function(store.get_all);
					do
						local ret, err = store:get_all("");
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
					do
						local ret, err = store:get_all(true);
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
				end);

				it("rejects empty or non-string keys to delete_all", function ()
					assert.is_function(store.delete_all);
					do
						local ret, err = store:delete_all("");
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
					do
						local ret, err = store:delete_all(true);
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
				end);

				it("may delete all instances of a specific key", function ()
					assert.is_function(store.delete_all);
					assert(store:set("user9999b", "foo", "hello"));

					assert(store:delete_all("bar"));
					-- Ensure key was deleted
					do
						local ret, err = store:get("user9999b", "bar");
						assert.is_nil(ret);
						assert.is_nil(err);
					end
					-- Ensure other users/keys are intact
					do
						local ret, err = store:get("user9999", "foo");
						assert.equal("bar", ret);
						assert.is_nil(err);
					end
					do
						local ret, err = store:get("user9999b", "foo");
						assert.equal("hello", ret);
						assert.is_nil(err);
					end
					do
						local ret, err = store:get("user9999c", "foo");
						assert.equal("blah", ret);
						assert.is_nil(err);
					end
				end);

				it("may remove data for a specific key for a user", function ()
					assert(store:set("user9999", "foo", nil));
					do
						local ret, err = store:get("user9999", "foo");
						assert.is_nil(ret);
						assert.is_nil(err);
					end

					assert(store:set("user9999b", "foo", nil));
					do
						local ret, err = store:get("user9999b", "foo");
						assert.is_nil(ret);
						assert.is_nil(err);
					end
				end);
			end);

			describe("keyval+ stores", function ()
				-- These tests rely on being executed in order, disable any order
				-- randomization for this block
				randomize(false);

				local store, kv_store, map_store;
				it("may be opened", function ()
					store = assert(sm.open(test_host, "test-kv+", "keyval+"));
				end);

				local simple_data = { foo = "bar" };

				it("may set data for a user", function ()
					assert(store:set("user9999", simple_data));
				end);

				it("may get data for a user", function ()
					assert.same(simple_data, assert(store:get("user9999")));
				end);

				it("may be opened as a keyval store", function ()
					kv_store = assert(sm.open(test_host, "test-kv+", "keyval"));
					assert.same(simple_data, assert(kv_store:get("user9999")));
				end);

				it("may be opened as a map store", function ()
					map_store = assert(sm.open(test_host, "test-kv+", "map"));
					assert.same("bar", assert(map_store:get("user9999", "foo")));
				end);

				it("may remove data for a user", function ()
					assert(store:set("user9999", nil));
					local ret, err = store:get("user9999");
					assert.is_nil(ret);
					assert.is_nil(err);
				end);


				it("may set a specific key for a user", function ()
					assert(store:set_key("user9999", "foo", "bar"));
					assert.same(kv_store:get("user9999"), { foo = "bar" });
				end);

				it("may get a specific key for a user", function ()
					assert.equal("bar", store:get_key("user9999", "foo"));
				end);

				it("may find all users with a specific key", function ()
					assert.is_function(store.get_key_from_all);
					assert(store:set_key("user9999b", "bar", "bar"));
					assert(store:set_key("user9999c", "foo", "blah"));
					local ret, err = store:get_key_from_all("foo");
					assert.is_nil(err);
					assert.same({ user9999 = "bar", user9999c = "blah" }, ret);
				end);

				it("rejects empty or non-string keys to get_all", function ()
					assert.is_function(store.get_key_from_all);
					do
						local ret, err = store:get_key_from_all("");
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
					do
						local ret, err = store:get_key_from_all(true);
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
				end);

				it("rejects empty or non-string keys to delete_all", function ()
					assert.is_function(store.delete_key_from_all);
					do
						local ret, err = store:delete_key_from_all("");
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
					do
						local ret, err = store:delete_key_from_all(true);
						assert.is_nil(ret);
						assert.is_not_nil(err);
					end
				end);

				it("may delete all instances of a specific key", function ()
					assert.is_function(store.delete_key_from_all);
					assert(store:set_key("user9999b", "foo", "hello"));

					assert(store:delete_key_from_all("bar"));
					-- Ensure key was deleted
					do
						local ret, err = store:get_key("user9999b", "bar");
						assert.is_nil(ret);
						assert.is_nil(err);
					end
					-- Ensure other users/keys are intact
					do
						local ret, err = store:get_key("user9999", "foo");
						assert.equal("bar", ret);
						assert.is_nil(err);
					end
					do
						local ret, err = store:get_key("user9999b", "foo");
						assert.equal("hello", ret);
						assert.is_nil(err);
					end
					do
						local ret, err = store:get_key("user9999c", "foo");
						assert.equal("blah", ret);
						assert.is_nil(err);
					end
				end);

				it("may remove data for a specific key for a user", function ()
					assert(store:set_key("user9999", "foo", nil));
					do
						local ret, err = store:get_key("user9999", "foo");
						assert.is_nil(ret);
						assert.is_nil(err);
					end

					assert(store:set_key("user9999b", "foo", nil));
					do
						local ret, err = store:get_key("user9999b", "foo");
						assert.is_nil(ret);
						assert.is_nil(err);
					end
				end);
			end);

			describe("archive stores", function ()
				randomize(false);

				local archive;
				it("can be opened", function ()
					archive = assert(sm.open(test_host, "test-archive", "archive"));
				end);

				local test_stanza = st.stanza("test", { xmlns = "urn:example:foo" })
					:tag("foo"):up()
					:tag("foo"):up()
					:reset();
				local test_time = 1539204123;

				local test_data = {
					{ nil, test_stanza, test_time-3, "contact@example.com" };
					{ nil, test_stanza, test_time-2, "contact2@example.com" };
					{ nil, test_stanza, test_time-1, "contact2@example.com" };
					{ nil, test_stanza, test_time+0, "contact2@example.com" };
					{ nil, test_stanza, test_time+1, "contact3@example.com" };
					{ nil, test_stanza, test_time+2, "contact3@example.com" };
					{ nil, test_stanza, test_time+3, "contact3@example.com" };
				};

				it("can be added to", function ()
					for _, data_item in ipairs(test_data) do
						local id = archive:append("user", unpack(data_item, 1, 4));
						assert.truthy(id);
						data_item[1] = id;
					end
				end);

				describe("can be queried", function ()
					it("for all items", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert.equal(test_data[count][3], when);
						end
						assert.equal(#test_data, count);
					end);

					it("by JID", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							with = "contact@example.com";
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert.equal(test_time-3, when);
						end
						assert.equal(1, count);
					end);

					it("by time (end)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["end"] = test_time;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(test_time >= when);
						end
						assert.equal(4, count);
					end);

					it("by time (start)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["start"] = test_time;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(when >= test_time, ("%d >= %d"):format(when, test_time));
						end
						assert.equal(#test_data - 3, count);
					end);

					it("by time (start before first item)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["start"] = test_time-5;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(when >= test_time-5, ("%d >= %d"):format(when, test_time-5));
						end
						assert.equal(#test_data, count);
					end);

					it("by time (start after last item)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["start"] = test_time+5;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(when >= test_time+5, ("%d >= %d"):format(when, test_time+5));
						end
						assert.equal(0, count);
					end);

					it("by time (start+end)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["start"] = test_time-1;
							["end"] = test_time+2;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(when >= test_time-1, ("%d >= %d"):format(when, test_time));
							assert(when <= test_time+2, ("%d <= %d"):format(when, test_time+1));
						end
						assert.equal(4, count);
					end);

					it("by id (after)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["after"] = test_data[2][1];
						});
						assert.truthy(data);
						local count = 0;
						for id, item in data do
							count = count + 1;
							assert.truthy(id);
							assert.equal(test_data[2+count][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
						end
						assert.equal(5, count);
					end);

					it("by id (before)", function ()
						-- luacheck: ignore 211/err
						local data, err = archive:find("user", {
							["before"] = test_data[4][1];
						});
						assert.truthy(data);
						local count = 0;
						for id, item in data do
							count = count + 1;
							assert.truthy(id);
							assert.equal(test_data[count][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
						end
						assert.equal(3, count);
					end);

					it("by id (before and after) #full_id_range", function ()
						assert.truthy(archive.caps and archive.caps.full_id_range, "full ID range support")
						local data, err = archive:find("user", {
								["after"] = test_data[1][1];
								["before"] = test_data[4][1];
							});
						assert.truthy(data, err);
						local count = 0;
						for id, item in data do
							count = count + 1;
							assert.truthy(id);
							assert.equal(test_data[1+count][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
						end
						assert.equal(2, count);
					end);

					it("by multiple ids", function ()
						assert.truthy(archive.caps and archive.caps.ids, "Multiple ID query")
						local data, err = archive:find("user", {
								["ids"] = {
									test_data[2][1];
									test_data[4][1];
								};
							});
						assert.truthy(data, err);
						local count = 0;
						for id, item in data do
							count = count + 1;
							assert.truthy(id);
							assert.equal(test_data[count==1 and 2 or 4][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
						end
						assert.equal(2, count);

					end);


					it("can be queried in reverse", function ()

						local data, err = archive:find("user", {
								reverse = true;
								limit = 3;
							});
						assert.truthy(data, err);

						local i = #test_data;
						for id, item in data do
							assert.truthy(id);
							assert.equal(test_data[i][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							i = i - 1;
						end

					end);

					-- This tests combines the reverse flag with 'before' and 'after' to
					-- ensure behaviour remains correct
					it("by id (before and after) in reverse #full_id_range", function ()
						assert.truthy(archive.caps and archive.caps.full_id_range, "full ID range support")
						local data, err = archive:find("user", {
								["after"] = test_data[1][1];
								["before"] = test_data[4][1];
								reverse = true;
							});
						assert.truthy(data, err);
						local count = 0;
						for id, item in data do
							count = count + 1;
							assert.truthy(id);
							assert.equal(test_data[4-count][1], id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
						end
						assert.equal(2, count);
					end);



				end);

				it("can selectively delete items", function ()
					local delete_id;
					do
						local data = assert(archive:find("user", {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/item 213/when
							count = count + 1;
							if count == 2 then
								delete_id = id;
							end
							assert.truthy(id);
						end
						assert.equal(#test_data, count);
					end

					assert(archive:delete("user", { key = delete_id }));

					do
						local data = assert(archive:find("user", {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/item 213/when
							count = count + 1;
							assert.truthy(id);
							assert.not_equal(delete_id, id);
						end
						assert.equal(#test_data-1, count);
					end
				end);

				it("can be purged", function ()
					-- luacheck: ignore 211/err
					local ok, err = archive:delete("user");
					assert.truthy(ok);
					local data, err = archive:find("user", {
						with = "contact@example.com";
					});
					assert.truthy(data, err);
					local count = 0;
					for id, item, when in data do -- luacheck: ignore id item when
						count = count + 1;
					end
					assert.equal(0, count);
				end);

				it("can truncate the oldest items", function ()
					local username = "user-truncate";
					for i = 1, 10 do
						assert(archive:append(username, nil, test_stanza, i, "contact@example.com"));
					end
					assert(archive:delete(username, { truncate = 3 }));

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/when
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert(when > 7, ("%d > 7"):format(when));
						end
						assert.equal(3, count);
					end
				end);

				it("overwrites existing keys with new data", function ()
					local prefix = ("a"):rep(50);
					local username = "user-overwrite";
					local a1 = assert(archive:append(username, prefix.."-1", test_stanza, test_time, "contact@example.com"));
					local a2 = assert(archive:append(username, prefix.."-2", test_stanza, test_time, "contact@example.com"));
					local ids = { a1, a2, };

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/when
							count = count + 1;
							assert.truthy(id);
							assert.equals(ids[count], id);
							assert(st.is_stanza(item));
						end
						assert.equal(2, count);
					end

					local new_stanza = st.clone(test_stanza);
					new_stanza.attr.foo = "bar";
					assert(archive:append(username, a2, new_stanza, test_time+1, "contact2@example.com"));

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert.equals(ids[count], id);
							assert(st.is_stanza(item));
							if count == 2 then
								assert.equals(test_time+1, when);
								assert.equals("bar", item.attr.foo);
							end
						end
						assert.equal(2, count);
					end
				end);

				it("can contain multiple long unique keys #issue1073", function ()
					local prefix = ("a"):rep(50);
					assert(archive:append("user-issue1073", prefix.."-1", test_stanza, test_time, "contact@example.com"));
					assert(archive:append("user-issue1073", prefix.."-2", test_stanza, test_time, "contact@example.com"));

					local data = assert(archive:find("user-issue1073", {}));
					local count = 0;
					for id, item, when in data do --luacheck: ignore 213/when
						count = count + 1;
						assert.truthy(id);
						assert(st.is_stanza(item));
					end
					assert.equal(2, count);
					assert(archive:delete("user-issue1073"));
				end);

				it("can be treated as a map store", function ()
					assert.falsy(archive:get("mapuser", "no-such-id"));
					assert.falsy(archive:set("mapuser", "no-such-id", test_stanza));

					local id = archive:append("mapuser", nil, test_stanza, test_time, "contact@example.com");
					do
						local stanza_roundtrip, when, with = archive:get("mapuser", id);
						assert.same(tostring(test_stanza), tostring(stanza_roundtrip), "same stanza is returned");
						assert.equal(test_time, when, "same 'when' is returned");
						assert.equal("contact@example.com", with, "same 'with' is returned");
					end

					local replacement_stanza = st.stanza("test", { xmlns = "urn:example:foo" })
						:tag("bar"):up()
						:reset();
					assert(archive:set("mapuser", id, replacement_stanza, test_time+1));

					do
						local replaced, when, with = archive:get("mapuser", id);
						assert.same(tostring(replacement_stanza), tostring(replaced), "replaced stanza is returned");
						assert.equal(test_time+1, when, "modified 'when' is returned");
						assert.equal("contact@example.com", with, "original 'with' is returned");
					end
				end);

				it("the summary api works", function()
					assert.truthy(archive:delete("summary-user"));
					local first_sid = archive:append("summary-user", nil, test_stanza, test_time, "contact@example.com");
					local second_sid = archive:append("summary-user", nil, test_stanza, test_time+1, "contact@example.com");
					assert.truthy(first_sid and second_sid, "preparations failed")
					---

					local user_summary, err = archive:summary("summary-user");
					assert.is_table(user_summary, err);
					assert.same({ ["contact@example.com"] = 2 }, user_summary.counts, "summary.counts matches");
					assert.same({ ["contact@example.com"] = test_time }, user_summary.earliest, "summary.earliest matches");
					assert.same({ ["contact@example.com"] = test_time+1 }, user_summary.latest, "summary.latest matches");
					if user_summary.body then
						assert.same({ ["contact@example.com"] = test_stanza:get_child_text("body") }, user_summary.body, "summary.body matches");
					end
				end);

			end);
		end);
	end
end);
