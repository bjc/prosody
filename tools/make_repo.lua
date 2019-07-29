print("Getting all the available modules")
if os.execute '[ -e "./downloaded_modules" ]' then
	os.execute("rm -rf downloaded_modules")
end
os.execute("hg clone https://hg.prosody.im/prosody-modules/ downloaded_modules")
local i, popen = 0, io.popen
local flag = "mod_"
if os.execute '[ -e "./repository" ]' then
	os.execute("mkdir repository")
end
local pfile = popen('ls -a "downloaded_modules"')
for filename in pfile:lines() do
	i = i + 1
	if filename:sub(1, #flag) == flag then
		local file = io.open("repository/"..filename.."-scm-1.rockspec", "w")
		file:write('package = "'..filename..'"', '\n')
		file:write('version = "scm-1"', '\n')
		file:write('source = {', '\n')
		file:write('\turl = "hg+https://hg.prosody.im/prosody-modules",', '\n')
		file:write('\tdir = "prosody-modules"', '\n')
		file:write('}', '\n')
		file:write('description = {', '\n')
		file:write('\thomepage = "https://prosody.im/",', '\n')
		file:write('\tlicense = "MIT"', '\n')
		file:write('}', '\n')
		file:write('dependencies = {', '\n')
		file:write('\t"lua >= 5.1"', '\n')
		file:write('}', '\n')
		file:write('build = {', '\n')
		file:write('\ttype = "builtin",', '\n')
		file:write('\tmodules = {', '\n')
		file:write('\t\t["'..filename..'.'..filename..'"] = "'..filename..'/'..filename..'.lua"', '\n')
		file:write('\t}', '\n')
		file:write('}', '\n')
		file:close()
	end
end
pfile:close()
os.execute("cd repository/ && luarocks-admin make_manifest ./ && chmod -R 644 ./*")
print("")
print("Done!. Modules' sources are locally available at ./downloaded_modules")
print("Repository is available at ./repository")
print("The repository contains all of prosody modules' respective rockspecs, as well as manifest files and an html Index")
print("You can now either point your server to this folder, or copy its contents to another configured folder.")
