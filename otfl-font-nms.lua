-- This lua script is made to generate the font database for LuaTeX, in order
-- for it to be able to load a font according to its name, like XeTeX does.
--
-- It is part of the luaotfload bundle, see luaotfload's README for legal
-- notice.
if not modules then modules = { } end modules ['font-nms'] = {
    version   = 1.002,
    comment   = "companion to luaotfload.lua",
    author    = "Khaled Hosny and Elie Roux",
    copyright = "Luaotfload Development Team",
    license   = "GPL"
}

fonts       = fonts       or { }
fonts.names = fonts.names or { }

local names = fonts.names

local splitpath, expandpath, glob, basename = file.split_path, kpse.expand_path, dir.glob, file.basename
local upper, format, rep = string.upper, string.format, string.rep

-- Log facilities:
-- - level 0 is quiet
-- - level 1 is the progress bar
-- - level 2 prints the searched directories
-- - level 3 prints all the loaded fonts
-- - level 4 prints all informations when searching directories (debug only)
names.log_level  = 1

local lastislog = 0

function names.log(lvl, fmt, ...)
    if lvl <= names.log_level then
        lastislog = 1
        texio.write_nl(format("luaotfload | %s", format(fmt,...)))
    end
end

local log = names.log

-- The progress bar
local function progress(current, total)
    if names.log_level == 1 then
--      local width   = os.getenv("COLUMNS") -2 --doesn't work
        local width   = 78
        local percent = current/total
        local gauge   = format("[%s]", string.rpadd(" ", width, " "))
        if percent > 0 then
            local done = string.rpadd("=", (width * percent) - 1, "=") .. ">"
            gauge = format("[%s]", string.rpadd(done, width, " ") )
        end
        if lastislog == 1 then
            texio.write_nl("")
            lastislog = 0
        end
        io.stderr:write("\r"..gauge)
        io.stderr:flush()
    end
end

function fontloader.fullinfo(...)
    local t = { }
    local f = fontloader.open(...)
    local m = f and fontloader.to_table(f)
    fontloader.close(f)
    -- see http://www.microsoft.com/typography/OTSPEC/features_pt.htm#size
    if m.fontstyle_name then
        for _,v in pairs(m.fontstyle_name) do
            if v.lang == 1033 then
                t.fontstyle_name = v.name
            end
        end
    end
    if m.names then
        for _,v in pairs(m.names) do
            if v.lang == "English (US)" then
                t.names = {
                    -- see http://developer.apple.com/textfonts/TTRefMan/RM06/Chap6name.html
                    fullname       = v.names.compatfull     or v.names.fullname, -- 18, 4
                    family         = v.names.preffamilyname or v.names.family,   -- 17, 1
                    subfamily      = t.fontstyle_name       or v.names.prefmodifiers  or v.names.subfamily, -- opt. style, 16, 2
                    psname         = v.names.postscriptname --or t.fontname
                }
            end
        end
    end
    t.fontname    = m.fontname
    t.fullname    = m.fullname
    t.familyname  = m.familyname
    t.filename    = m.origname
    t.weight      = m.pfminfo.weight
    t.width       = m.pfminfo.width
    t.slant       = m.italicangle
    -- don't waste the space with zero values
    t.size = {
        m.design_size         ~= 0 and m.design_size         or nil,
        m.design_range_top    ~= 0 and m.design_range_top    or nil,
        m.design_range_bottom ~= 0 and m.design_range_bottom or nil,
    }
    return t
end

local function load_font(filename, fontnames, texmf)
    log(3, "Loading font: %s", filename)
    local database  = fontnames
    local mappings  = database.mappings  or { }
    local families  = database.families  or { }
    local checksums = database.checksums or { }
    if filename then
        local checksum = file.checksum(filename)
        if checksums[checksum] and checksums[checksum] == filename then
            log(3, "Font already indexed: %s", filename)
            return fontnames
        end
        checksums[checksum] = filename
        local info = fontloader.info(filename)
        if info then
            if type(info) == "table" and #info > 1 then
                for index,_ in ipairs(info) do
                    local fullinfo = fontloader.fullinfo(filename, index-1)
                    if texmf then
                        fullinfo.filename = basename(filename)
                    end
                    mappings[#mappings+1] = fullinfo
                    if fullinfo.names.family then
                        if not families[fullinfo.names.family] then
                            families[fullinfo.names.family] = { }
                        end
                        table.insert(families[fullinfo.names.family], #mappings)
                    else
                        log(3, "Warning: font with broken names table: %s, ignored", filename)
                    end
                end
            else
                local fullinfo = fontloader.fullinfo(filename)
                if texmf then
                    fullinfo.filename = basename(filename)
                end
                mappings[#mappings+1] = fullinfo
                if fullinfo.names.family then
                    if not families[fullinfo.names.family] then
                        families[fullinfo.names.family] = { }
                    end
                    table.insert(families[fullinfo.names.family], #mappings)
                else
                    log(3, "Warning: font with broken names table: %s, ignored", filename)
                end
            end
        else
            log(1, "Failed to load %s", filename)
        end
    end
    return database
end

-- We need to detect the OS (especially cygwin) to convert paths.
local system = LUAROCKS_UNAME_S or io.popen("uname -s"):read("*l")
if system then
    if system:match("^CYGWIN") then
        system = 'cygwin'
    elseif system:match("^Windows") then
        system = 'windows'
    else
        system = 'unix'
    end
else
    system = 'unix' -- ?
end
log(2, "Detecting system: %s", system)

-- path normalization:
-- - a\b\c  -> a/b/c
-- - a/../b -> b
-- - /cygdrive/a/b -> a:/b
local function path_normalize(path)
    if system ~= 'unix' then
        path = path:gsub('\\', '/')
        path = path:lower()
    end
    path = file.collapse_path(path)
    if system == "cygwin" then
        path = path:gsub('^/cygdrive/(%a)/', '%1:/')
    end
    return path
end

-- this function scans a directory and populates the list of fonts
-- with all the fonts it finds.
-- - dirname is the name of the directory to scan
-- - names is the font database to fill
-- - recursive is whether we scan all directories recursively (always false
--       in this script)
-- - texmf is a boolean saying if we are scanning a texmf directory (always
--       true in this script)
local function scan_dir(dirname, fontnames, recursive, texmf)
    local list, found = { }, { }
    local nbfound = 0
    for _,ext in ipairs { "otf", "ttf", "ttc", "dfont" } do
        if recursive then pat = "/**." else pat = "/*." end
        log(4, "Scanning '%s' for '%s' fonts", dirname, ext)
        found = glob(dirname .. pat .. ext)
        -- note that glob fails silently on broken symlinks, which happens
        -- sometimes in TeX Live.
        log(4, "%s fonts found", #found)
        nbfound = nbfound + #found
        table.append(list, found)
        log(4, "Scanning '%s' for '%s' fonts", dirname, upper(ext))
        found = glob(dirname .. pat .. upper(ext))
        table.append(list, found)
        nbfound = nbfound + #found
    end
    log(2, "%d fonts found in '%s'", nbfound, dirname)
    for _,fnt in ipairs(list) do
        fnt = path_normalize(fnt)
        fontnames = load_font(fnt, fontnames, texmf)
    end
    return fontnames
end

-- The function that scans all fonts in the texmf tree, through kpathsea
-- variables OPENTYPEFONTS and TTFONTS of texmf.cnf
local function scan_texmf_tree(fontnames)
    if expandpath("$OSFONTDIR"):is_empty() then
        log(1, "Scanning TEXMF fonts:")
    else
        log(1, "Scanning TEXMF and OS fonts:")
    end
    local fontdirs = expandpath("$OPENTYPEFONTS")
    fontdirs = fontdirs .. string.gsub(expandpath("$TTFONTS"), "^\.", "")
    if not fontdirs:is_empty() then
        local explored_dirs = {}
        fontdirs = splitpath(fontdirs)
        -- hack, don't scan current dir
        table.remove(fontdirs, 1)
        count = 0
        for _,d in ipairs(fontdirs) do
            if not explored_dirs[d] then
                count = count + 1
                progress(count, #fontdirs)
                fontnames = scan_dir(d, fontnames, false, true)
                explored_dirs[d] = true
            end
        end
    end
    return fontnames
end

-- this function takes raw data returned by fc-list, parses it, normalizes the
-- paths and makes a list out of it.
local function read_fcdata(data)
    local list = { }
    for line in data:lines() do
        line = line:gsub(": ", "")
        local ext = string.lower(string.match(line,"^.+%.([^/\\]-)$"))
        if ext == "otf" or ext == "ttf" or ext == "ttc" or ext == "dfont" then
            list[#list+1] = path_normalize(line:gsub(": ", ""))
        end
    end
    return list
end

-- This function scans the OS fonts through fontcache (fc-list), it executes
-- only if OSFONTDIR is empty (which is the case under most Unix by default).
-- If OSFONTDIR is non-empty, this means that the system fonts it contains have
-- already been scanned, and thus we don't scan them again.
local function scan_os_fonts(fontnames)
    if expandpath("$OSFONTDIR"):is_empty() then 
        log(1, "Scanning system fonts:")
        log(2, "Executing 'fc-list : file'")
        local data = io.popen("fc-list : file", 'r')
        log(2, "Parsing the result...")
        local list = read_fcdata(data)
        data:close()
        log(2, "%d fonts found", #list)
        log(2, "Scanning...", #list)
        count = 0
        for _,fnt in ipairs(list) do
            count = count + 1
            progress(count, #list)
            fontnames = load_font(fnt, fontnames, false)
        end
    end
    return fontnames
end

local function fontnames_init()
    return {
        mappings  = { },
        families  = { },
        checksums = { },
        version   = names.version,
    }
end

-- The main function, scans everything
local function update(fontnames,force)
    if force then
        fontnames = fontnames_init()
    else
	if fontnames and fontnames.version and fontnames.version == names.version then
        else
            log(2, "Old font names database version, generating new one")
            fontnames = fontnames_init()
        end
    end
    fontnames = scan_texmf_tree(fontnames)
    fontnames = scan_os_fonts  (fontnames)
    return fontnames
end

names.scan   = scan_dir
names.update = update