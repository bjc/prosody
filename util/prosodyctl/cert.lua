local lfs = require "lfs";

local pctl = require "util.prosodyctl";
local configmanager = require "core.configmanager";

local openssl;

local cert_commands = {};

-- If a file already exists, ask if the user wants to use it or replace it
-- Backups the old file if replaced
local function use_existing(filename)
	local attrs = lfs.attributes(filename);
	if attrs then
		if pctl.show_yesno(filename .. " exists, do you want to replace it? [y/n]") then
			local backup = filename..".bkp~"..os.date("%FT%T", attrs.change);
			os.rename(filename, backup);
			pctl.show_message("%s backed up to %s", filename, backup);
		else
			-- Use the existing file
			return true;
		end
	end
end

local have_pposix, pposix = pcall(require, "util.pposix");
local cert_basedir = prosody.paths.data == "." and "./certs" or prosody.paths.data;
if have_pposix and pposix.getuid() == 0 then
	-- FIXME should be enough to check if this directory is writable
	local cert_dir = configmanager.get("*", "certificates") or "certs";
	cert_basedir = configmanager.resolve_relative_path(prosody.paths.config, cert_dir);
end

function cert_commands.config(arg)
	if #arg >= 1 and arg[1] ~= "--help" then
		local conf_filename = cert_basedir .. "/" .. arg[1] .. ".cnf";
		if use_existing(conf_filename) then
			return nil, conf_filename;
		end
		local distinguished_name;
		if arg[#arg]:find("^/") then
			distinguished_name = table.remove(arg);
		end
		local conf = openssl.config.new();
		conf:from_prosody(prosody.hosts, configmanager, arg);
		if distinguished_name then
			local dn = {};
			for k, v in distinguished_name:gmatch("/([^=/]+)=([^/]+)") do
				table.insert(dn, k);
				dn[k] = v;
			end
			conf.distinguished_name = dn;
		else
			pctl.show_message("Please provide details to include in the certificate config file.");
			pctl.show_message("Leave the field empty to use the default value or '.' to exclude the field.")
			for _, k in ipairs(openssl._DN_order) do
				local v = conf.distinguished_name[k];
				if v then
					local nv = nil;
					if k == "commonName" then
						v = arg[1]
					elseif k == "emailAddress" then
						v = "xmpp@" .. arg[1];
					elseif k == "countryName" then
						local tld = arg[1]:match"%.([a-z]+)$";
						if tld and #tld == 2 and tld ~= "uk" then
							v = tld:upper();
						end
					end
					nv = pctl.show_prompt(("%s (%s):"):format(k, nv or v));
					nv = (not nv or nv == "") and v or nv;
					if nv:find"[\192-\252][\128-\191]+" then
						conf.req.string_mask = "utf8only"
					end
					conf.distinguished_name[k] = nv ~= "." and nv or nil;
				end
			end
		end
		local conf_file, err = io.open(conf_filename, "w");
		if not conf_file then
			pctl.show_warning("Could not open OpenSSL config file for writing");
			pctl.show_warning(err);
			os.exit(1);
		end
		conf_file:write(conf:serialize());
		conf_file:close();
		print("");
		pctl.show_message("Config written to %s", conf_filename);
		return nil, conf_filename;
	else
		pctl.show_usage("cert config HOSTNAME [HOSTNAME+]", "Builds a certificate config file covering the supplied hostname(s)")
	end
end

function cert_commands.key(arg)
	if #arg >= 1 and arg[1] ~= "--help" then
		local key_filename = cert_basedir .. "/" .. arg[1] .. ".key";
		if use_existing(key_filename) then
			return nil, key_filename;
		end
		os.remove(key_filename); -- This file, if it exists is unlikely to have write permissions
		local key_size = tonumber(arg[2] or pctl.show_prompt("Choose key size (2048):") or 2048);
		local old_umask = pposix.umask("0377");
		if openssl.genrsa{out=key_filename, key_size} then
			os.execute(("chmod 400 '%s'"):format(key_filename));
			pctl.show_message("Key written to %s", key_filename);
			pposix.umask(old_umask);
			return nil, key_filename;
		end
		pctl.show_message("There was a problem, see OpenSSL output");
	else
		pctl.show_usage("cert key HOSTNAME <bits>", "Generates a RSA key named HOSTNAME.key\n "
		.."Prompts for a key size if none given")
	end
end

function cert_commands.request(arg)
	if #arg >= 1 and arg[1] ~= "--help" then
		local req_filename = cert_basedir .. "/" .. arg[1] .. ".req";
		if use_existing(req_filename) then
			return nil, req_filename;
		end
		local _, key_filename = cert_commands.key({arg[1]});
		local _, conf_filename = cert_commands.config(arg);
		if openssl.req{new=true, key=key_filename, utf8=true, sha256=true, config=conf_filename, out=req_filename} then
			pctl.show_message("Certificate request written to %s", req_filename);
		else
			pctl.show_message("There was a problem, see OpenSSL output");
		end
	else
		pctl.show_usage("cert request HOSTNAME [HOSTNAME+]", "Generates a certificate request for the supplied hostname(s)")
	end
end

function cert_commands.generate(arg)
	if #arg >= 1 and arg[1] ~= "--help" then
		local cert_filename = cert_basedir .. "/" .. arg[1] .. ".crt";
		if use_existing(cert_filename) then
			return nil, cert_filename;
		end
		local _, key_filename = cert_commands.key({arg[1]});
		local _, conf_filename = cert_commands.config(arg);
		if key_filename and conf_filename and cert_filename
			and openssl.req{new=true, x509=true, nodes=true, key=key_filename,
				days=365, sha256=true, utf8=true, config=conf_filename, out=cert_filename} then
			pctl.show_message("Certificate written to %s", cert_filename);
			print();
		else
			pctl.show_message("There was a problem, see OpenSSL output");
		end
	else
		pctl.show_usage("cert generate HOSTNAME [HOSTNAME+]", "Generates a self-signed certificate for the current hostname(s)")
	end
end

local function sh_esc(s)
	return "'" .. s:gsub("'", "'\\''") .. "'";
end

local function copy(from, to, umask, owner, group)
	local old_umask = umask and pposix.umask(umask);
	local attrs = lfs.attributes(to);
	if attrs then -- Move old file out of the way
		local backup = to..".bkp~"..os.date("%FT%T", attrs.change);
		os.rename(to, backup);
	end
	-- FIXME friendlier error handling, maybe move above backup back?
	local input = assert(io.open(from));
	local output = assert(io.open(to, "w"));
	local data = input:read(2^11);
	while data and output:write(data) do
		data = input:read(2^11);
	end
	assert(input:close());
	assert(output:close());
	if not prosody.installed then
		-- FIXME this is possibly specific to GNU chown
		os.execute(("chown -c --reference=%s %s"):format(sh_esc(cert_basedir), sh_esc(to)));
	elseif owner and group then
		local ok = os.execute(("chown %s:%s %s"):format(sh_esc(owner), sh_esc(group), sh_esc(to)));
		assert(ok == true or ok == 0, "Failed to change ownership of "..to);
	end
	if old_umask then pposix.umask(old_umask); end
	return true;
end

function cert_commands.import(arg)
	local hostnames = {};
	-- Move hostname arguments out of arg, the rest should be a list of paths
	while arg[1] and prosody.hosts[ arg[1] ] do
		table.insert(hostnames, table.remove(arg, 1));
	end
	if hostnames[1] == nil then
		local domains = os.getenv"RENEWED_DOMAINS"; -- Set if invoked via certbot
		if domains then
			for host in domains:gmatch("%S+") do
				table.insert(hostnames, host);
			end
		else
			for host in pairs(prosody.hosts) do
				if host ~= "*" and configmanager.get(host, "enabled") ~= false then
					table.insert(hostnames, host);
				end
			end
		end
	end
	if not arg[1] or arg[1] == "--help" then -- Probably forgot the path
		pctl.show_usage("cert import [HOSTNAME+] /path/to/certs [/other/paths/]+",
			"Copies certificates to "..cert_basedir);
		return 1;
	end
	local owner, group;
	if pposix.getuid() == 0 then -- We need root to change ownership
		owner = configmanager.get("*", "prosody_user") or "prosody";
		group = configmanager.get("*", "prosody_group") or owner;
	end
	local cm = require "core.certmanager";
	local imported = {};
	for _, host in ipairs(hostnames) do
		for _, dir in ipairs(arg) do
			local paths = cm.find_cert(dir, host);
			if paths then
				copy(paths.certificate, cert_basedir .. "/" .. host .. ".crt", nil, owner, group);
				copy(paths.key, cert_basedir .. "/" .. host .. ".key", "0377", owner, group);
				table.insert(imported, host);
			else
				-- TODO Say where we looked
				pctl.show_warning("No certificate for host "..host.." found :(");
			end
			-- TODO Additional checks
			-- Certificate names matches the hostname
			-- Private key matches public key in certificate
		end
	end
	if imported[1] then
		pctl.show_message("Imported certificate and key for hosts %s", table.concat(imported, ", "));
		local ok, err = pctl.reload();
		if not ok and err ~= "not-running" then
			pctl.show_message(pctl.error_messages[err]);
		end
	else
		pctl.show_warning("No certificates imported :(");
		return 1;
	end
end

local function cert(arg)
	if #arg >= 1 and arg[1] ~= "--help" then
		openssl = require "util.openssl";
		lfs = require "lfs";
		local cert_dir_attrs = lfs.attributes(cert_basedir);
		if not cert_dir_attrs then
			pctl.show_warning("The directory "..cert_basedir.." does not exist");
			return 1; -- TODO Should we create it?
		end
		local uid = pposix.getuid();
		if uid ~= 0 and uid ~= cert_dir_attrs.uid then
			pctl.show_warning("The directory "..cert_basedir.." is not owned by the current user, won't be able to write files to it");
			return 1;
		elseif not cert_dir_attrs.permissions then -- COMPAT with LuaFilesystem < 1.6.2 (hey CentOS!)
			pctl.show_message("Unable to check permissions on %s (LuaFilesystem 1.6.2+ required)", cert_basedir);
			pctl.show_message("Please confirm that Prosody (and only Prosody) can write to this directory)");
		elseif cert_dir_attrs.permissions:match("^%.w..%-..%-.$") then
			pctl.show_warning("The directory "..cert_basedir.." not only writable by its owner");
			return 1;
		end
		local subcmd = table.remove(arg, 1);
		if type(cert_commands[subcmd]) == "function" then
			if subcmd ~= "import" then -- hostnames are optional for import
				if not arg[1] then
					pctl.show_message"You need to supply at least one hostname"
					arg = { "--help" };
				end
				if arg[1] ~= "--help" and not prosody.hosts[arg[1]] then
					pctl.show_message(pctl.error_messages["no-such-host"]);
					return 1;
				end
			end
			return cert_commands[subcmd](arg);
		elseif subcmd == "check" then
			return require "util.prosodyctl.check".check({"certs"});
		end
	end
	pctl.show_usage("cert config|request|generate|key|import", "Helpers for generating X.509 certificates and keys.")
	for _, cmd in pairs(cert_commands) do
		print()
		cmd{ "--help" }
	end
end

return {
	cert = cert;
};
