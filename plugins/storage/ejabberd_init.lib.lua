
local t_concat = table.concat;
local t_insert = table.insert;
local pairs = pairs;
local DBI = require "DBI";

local sqlite = true;
local q = {};

local function set(key, val)
--	t_insert(q, "SET "..key.."="..val..";\n")
end
local function create_table(name, fields)
	t_insert(q, "CREATE TABLE ".."IF NOT EXISTS "..name.." (\n");
	for _, field in pairs(fields) do
		t_insert(q, "\t");
		field = t_concat(field, " ");
		if sqlite then
			if field:lower():match("^primary key *%(") then field = field:gsub("%(%d+%)", ""); end
		end
		t_insert(q, field);
		if _ ~= #fields then t_insert(q, ",\n"); end
		t_insert(q, "\n");
	end
	if sqlite then
		t_insert(q, ");\n");
	else
		t_insert(q, ") CHARACTER SET utf8;\n");
	end
end
local function create_index(name, index)
	--t_insert(q, "CREATE INDEX "..name.." ON "..index..";\n");
end
local function create_unique_index(name, index)
	--t_insert(q, "CREATE UNIQUE INDEX "..name.." ON "..index..";\n");
end
local function insert(target, value)
	t_insert(q, "INSERT INTO "..target.."\nVALUES "..value..";\n");
end
local function foreign_key(name, fkey, fname, fcol)
	t_insert(q, "ALTER TABLE `"..name.."` ADD FOREIGN KEY (`"..fkey.."`) REFERENCES `"..fname.."` (`"..fcol.."`) ON DELETE CASCADE;\n");
end

function build_query()
	q = {};
	set('table_type', 'InnoDB');
	create_table('hosts', {
		{'clusterid','integer','NOT','NULL'};
		{'host','varchar(250)','NOT','NULL','PRIMARY','KEY'};
		{'config','text','NOT','NULL'};
	});
	insert("hosts (clusterid, host, config)", "(1, 'localhost', '')");
	create_table('users', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'password','text','NOT','NULL'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host, username)'};
	});
	create_table('last', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'seconds','text','NOT','NULL'};
		{'state','text','NOT','NULL'};
		{'PRIMARY','KEY','(host, username)'};
	});
	create_table('rosterusers', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'jid','varchar(250)','NOT','NULL'};
		{'nick','text','NOT','NULL'};
		{'subscription','character(1)','NOT','NULL'};
		{'ask','character(1)','NOT','NULL'};
		{'askmessage','text','NOT','NULL'};
		{'server','character(1)','NOT','NULL'};
		{'subscribe','text','NOT','NULL'};
		{'type','text'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host(75), username(75), jid(75))'};
	});
	create_index('i_rosteru_username', 'rosterusers(username)');
	create_index('i_rosteru_jid', 'rosterusers(jid)');
	create_table('rostergroups', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'jid','varchar(250)','NOT','NULL'};
		{'grp','text','NOT','NULL'};
		{'PRIMARY','KEY','(host(75), username(75), jid(75))'};
	});
	--[[create_table('spool', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'xml','text','NOT','NULL'};
		{'seq','BIGINT','UNSIGNED','NOT','NULL','AUTO_INCREMENT','UNIQUE'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host, username, seq)'};
	});]]
	create_table('vcard', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'vcard','text','NOT','NULL'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host, username)'};
	});
	create_table('vcard_search', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'lusername','varchar(250)','NOT','NULL'};
		{'fn','text','NOT','NULL'};
		{'lfn','varchar(250)','NOT','NULL'};
		{'family','text','NOT','NULL'};
		{'lfamily','varchar(250)','NOT','NULL'};
		{'given','text','NOT','NULL'};
		{'lgiven','varchar(250)','NOT','NULL'};
		{'middle','text','NOT','NULL'};
		{'lmiddle','varchar(250)','NOT','NULL'};
		{'nickname','text','NOT','NULL'};
		{'lnickname','varchar(250)','NOT','NULL'};
		{'bday','text','NOT','NULL'};
		{'lbday','varchar(250)','NOT','NULL'};
		{'ctry','text','NOT','NULL'};
		{'lctry','varchar(250)','NOT','NULL'};
		{'locality','text','NOT','NULL'};
		{'llocality','varchar(250)','NOT','NULL'};
		{'email','text','NOT','NULL'};
		{'lemail','varchar(250)','NOT','NULL'};
		{'orgname','text','NOT','NULL'};
		{'lorgname','varchar(250)','NOT','NULL'};
		{'orgunit','text','NOT','NULL'};
		{'lorgunit','varchar(250)','NOT','NULL'};
		{'PRIMARY','KEY','(host, lusername)'};
	});
	create_index('i_vcard_search_lfn      ', 'vcard_search(lfn)');
	create_index('i_vcard_search_lfamily  ', 'vcard_search(lfamily)');
	create_index('i_vcard_search_lgiven   ', 'vcard_search(lgiven)');
	create_index('i_vcard_search_lmiddle  ', 'vcard_search(lmiddle)');
	create_index('i_vcard_search_lnickname', 'vcard_search(lnickname)');
	create_index('i_vcard_search_lbday    ', 'vcard_search(lbday)');
	create_index('i_vcard_search_lctry    ', 'vcard_search(lctry)');
	create_index('i_vcard_search_llocality', 'vcard_search(llocality)');
	create_index('i_vcard_search_lemail   ', 'vcard_search(lemail)');
	create_index('i_vcard_search_lorgname ', 'vcard_search(lorgname)');
	create_index('i_vcard_search_lorgunit ', 'vcard_search(lorgunit)');
	create_table('privacy_default_list', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)'};
		{'name','varchar(250)','NOT','NULL'};
		{'PRIMARY','KEY','(host, username)'};
	});
	--[[create_table('privacy_list', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'name','varchar(250)','NOT','NULL'};
		{'id','BIGINT','UNSIGNED','NOT','NULL','AUTO_INCREMENT','UNIQUE'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host, username, name)'};
	});]]
	create_table('privacy_list_data', {
		{'id','bigint'};
		{'t','character(1)','NOT','NULL'};
		{'value','text','NOT','NULL'};
		{'action','character(1)','NOT','NULL'};
		{'ord','NUMERIC','NOT','NULL'};
		{'match_all','boolean','NOT','NULL'};
		{'match_iq','boolean','NOT','NULL'};
		{'match_message','boolean','NOT','NULL'};
		{'match_presence_in','boolean','NOT','NULL'};
		{'match_presence_out','boolean','NOT','NULL'};
	});
	create_table('private_storage', {
		{'host','varchar(250)','NOT','NULL'};
		{'username','varchar(250)','NOT','NULL'};
		{'namespace','varchar(250)','NOT','NULL'};
		{'data','text','NOT','NULL'};
		{'created_at','timestamp','NOT','NULL','DEFAULT','CURRENT_TIMESTAMP'};
		{'PRIMARY','KEY','(host(75), username(75), namespace(75))'};
	});
	create_index('i_private_storage_username USING BTREE', 'private_storage(username)');
	create_table('roster_version', {
		{'username','varchar(250)','PRIMARY','KEY'};
		{'version','text','NOT','NULL'};
	});
	--[[create_table('pubsub_node', {
		{'host','text'};
		{'node','text'};
		{'parent','text'};
		{'type','text'};
		{'nodeid','bigint','auto_increment','primary','key'};
	});
	create_index('i_pubsub_node_parent', 'pubsub_node(parent(120))');
	create_unique_index('i_pubsub_node_tuple', 'pubsub_node(host(20), node(120))');
	create_table('pubsub_node_option', {
		{'nodeid','bigint'};
		{'name','text'};
		{'val','text'};
	});
	create_index('i_pubsub_node_option_nodeid', 'pubsub_node_option(nodeid)');
	foreign_key('pubsub_node_option', 'nodeid', 'pubsub_node', 'nodeid');
	create_table('pubsub_node_owner', {
		{'nodeid','bigint'};
		{'owner','text'};
	});
	create_index('i_pubsub_node_owner_nodeid', 'pubsub_node_owner(nodeid)');
	foreign_key('pubsub_node_owner', 'nodeid', 'pubsub_node', 'nodeid');
	create_table('pubsub_state', {
		{'nodeid','bigint'};
		{'jid','text'};
		{'affiliation','character(1)'};
		{'subscriptions','text'};
		{'stateid','bigint','auto_increment','primary','key'};
	});
	create_index('i_pubsub_state_jid', 'pubsub_state(jid(60))');
	create_unique_index('i_pubsub_state_tuple', 'pubsub_state(nodeid, jid(60))');
	foreign_key('pubsub_state', 'nodeid', 'pubsub_node', 'nodeid');
	create_table('pubsub_item', {
		{'nodeid','bigint'};
		{'itemid','text'};
		{'publisher','text'};
		{'creation','text'};
		{'modification','text'};
		{'payload','text'};
	});
	create_index('i_pubsub_item_itemid', 'pubsub_item(itemid(36))');
	create_unique_index('i_pubsub_item_tuple', 'pubsub_item(nodeid, itemid(36))');
	foreign_key('pubsub_item', 'nodeid', 'pubsub_node', 'nodeid');
	create_table('pubsub_subscription_opt', {
		{'subid','text'};
		{'opt_name','varchar(32)'};
		{'opt_value','text'};
	});
	create_unique_index('i_pubsub_subscription_opt', 'pubsub_subscription_opt(subid(32), opt_name(32))');]]
	return t_concat(q);
end

local function init(dbh)
	local q = build_query();
	for statement in q:gmatch("[^;]*;") do
		statement = statement:gsub("\n", ""):gsub("\t", " ");
		if sqlite then
			statement = statement:gsub("AUTO_INCREMENT", "AUTOINCREMENT");
			statement = statement:gsub("auto_increment", "autoincrement");
		end
		local result, err = DBI.Do(dbh, statement);
		if not result then
			print("X", result, err);
			print("Y", statement);
		end
	end
end

local _M = { init = init };
return _M;
