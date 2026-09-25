--=============================================================================
--  autosub.lua — automatic subtitle download via subliminal
--
--  Requires the `subliminal` CLI (pip install subliminal).
--  Binary location: `autosub_subliminal_path` script-opt, otherwise
--  auto-discovered from PATH, with a fallback to a known venv path.
--
--  All knobs live in script-opts/autosub.conf or on the mpv command line
--  via --script-opts=autosub_<name>=<value> (a hyphenated
--  autosub-<name>=<value> spelling is accepted on the CLI as well).
--=============================================================================

local utils = require 'mp.utils'

-- Human-readable names for the language codes configured below.
-- Fallback name = the iso code itself.
local lang_names = {
    en='English',     eng='English',
    nl='Dutch',       dut='Dutch',
    es='Spanish',     spa='Spanish',
    fr='French',      fre='French',
    de='German',      ger='German',
    it='Italian',     ita='Italian',
    pt='Portuguese',  por='Portuguese',
    pl='Polish',      pol='Polish',
    ru='Russian',     rus='Russian',
    zh='Chinese',     chi='Chinese',
    ar='Arabic',      ara='Arabic',
    ja='Japanese',    jpn='Japanese',
    ko='Korean',      kor='Korean',
    hi='Hindi',       hin='Hindi',
}

-- Defaults; overridable via script-opts/autosub.conf or --script-opts.
local defaults = {
    auto            = 'yes',  -- Auto-download on file load (no hotkey needed)
    languages       = 'en,eng,nl,dut', -- Comma list; iso codes pair up
                                        -- 2-by-2 into (iso639-1, iso639-2)
    subliminal_path = '',     -- Empty => auto-discover via PATH
    providers       = 'opensubtitlescom,podnapisi', -- Only live providers
    dir             = '',     -- Empty => ~/.cache/mpv/subtitles/<video-name>
    extra_args      = '',     -- Extra CLI tokens appended before the file
    timeout         = '30',   -- Wall-clock budget in seconds for subliminal
    excludes        = 'no-subs-dl', -- Paths containing these are skipped
    includes        = '',     -- If set, only paths containing these download
    debug           = 'no',   -- Add --debug to subliminal, extra logging
}

-- Quote a string for safe use in a single shell command line.
local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- mp.get_opt() only sees --script-opts CLI values; script-opts/*.conf files
-- are NOT visible to it (mpv <= 0.41 behaviour). So we read the conf file
-- ourselves, then let CLI values win. Lines starting with '#' are comments,
-- matching mpv's config-file convention.
local function read_conf_file()
    local out = {}
    local path = mp.find_config_file and mp.find_config_file('script-opts/autosub.conf')
    if not path then return out end
    local f = io.open(path, 'r')
    if not f then return out end
    for line in f:lines() do
        line = line:gsub('\r$', '')
        if line:sub(1, 1) ~= '#' then
            local eq = line:find('=')
            if eq then
                local k = line:sub(1, eq - 1):gsub('^%s+', ''):gsub('%s+$', '')
                local v = line:sub(eq + 1):gsub('^%s+', ''):gsub('%s+$', '')
                if k ~= '' then out[k] = v end
            end
        end
    end
    f:close()
    return out
end

-- Merge: defaults < autosub.conf < --script-opts (CLI wins).
local conf = read_conf_file()
local opts = {}
for k, default in pairs(defaults) do
    local key = 'autosub_' .. k
    local cli = mp.get_opt(key)
    -- NOTE: (..) around gsub discards its second return value (the
    -- substitution count); without it, that count leaked into mp.get_opt
    -- as the default and every option collapsed to "1"/"2".
    if cli == nil then cli = mp.get_opt((key:gsub('_', '-'))) end
    local raw = cli
    if raw == nil then raw = conf[key] end
    if raw == nil then raw = default end
    opts[k] = raw
end

local function to_bool(v)
    if type(v) == 'boolean' then return v end
    v = tostring(v):lower()
    return v == 'yes' or v == 'true' or v == '1' or v == 'on'
end

opts.auto = to_bool(opts.auto)
opts.debug = to_bool(opts.debug)
opts.timeout = tonumber(opts.timeout) or 30

-- Locate the subliminal binary: explicit option > PATH > known venv path.
local function find_subliminal()
    if opts.subliminal_path ~= '' then return opts.subliminal_path end
    local probe = io.popen('command -v subliminal 2>/dev/null')
    if probe then
        local found = probe:read('*l')
        probe:close()
        if found and found ~= '' then return found end
    end
    return '/home/deck/.venv/global/bin/subliminal'
end
local subliminal = find_subliminal()

-- Pair the language codes 2-by-2 into {name, iso639-1, iso639-2} tuples.
local languages = {}
local codes = {}
for code in tostring(opts.languages):gmatch('[^,]+') do
    code = code:gsub('^%s+', ''):gsub('%s+$', '')
    if code ~= '' then codes[#codes + 1] = code end
end
for i = 1, #codes, 2 do
    local iso1, iso2 = codes[i], codes[i + 1]
    local name = lang_names[iso1] or lang_names[iso2] or iso1
    languages[#languages + 1] = { name, iso1, iso2 }
end

-- Providers: one -p flag per provider (subliminal >= 2.7 rejects a
-- comma-separated list in a single -p).
local providers = {}
for p in tostring(opts.providers):gmatch('[^,%s]+') do
    if p ~= '' then providers[#providers + 1] = p end
end

local excludes = {}
for e in tostring(opts.excludes):gmatch('[^,%s]+') do
    if e ~= '' then excludes[#excludes + 1] = e end
end

local includes = {}
for i in tostring(opts.includes):gmatch('[^,%s]+') do
    if i ~= '' then includes[#includes + 1] = i end
end

-- Set by control_downloads(); read by the other functions below.
local directory, filename, sub_tracks

-- Log function: log to both terminal and MPV OSD (On-Screen Display)
function log(string, secs)
    secs = secs or 2.5  -- secs defaults to 2.5 when secs parameter is absent
    mp.msg.warn(string)          -- This logs to the terminal
    mp.osd_message(string, secs) -- This logs to MPV screen
end

-- Path of the newest .srt/.ass/.sub in dir newer than the given timestamp,
-- or nil. Uses `find` because mpv 0.41 exposes neither utils.stat nor
-- readdir; find lists newest first, so the first line is the newest file.
local function newest_subtitle_in(dir, since)
    local f = io.popen('find ' .. shq(dir) ..
        ' -maxdepth 1 -type f \\( -iname "*.srt" -o -iname "*.ass" ' ..
        '-o -iname "*.sub" \\) -newermt @' .. tonumber(since) ..
        ' 2>/dev/null')
    if not f then return nil end
    local found = f:read('*l')
    f:close()
    return found
end

-- Download function: download the best subtitles in the preferred language.
-- Runs non-blocking; on completion calls done(success).
function download_subs(language, done)
    done = done or function() end
    language = language or languages[1]
    if not language or #language == 0 then
        log('No Language found\n')
        done(false)
        return false
    end

    if not filename or filename == '' then
        log('No file loaded to download subtitles for')
        done(false)
        return false
    end

    log('Searching ' .. language[1] .. ' subtitles ...', 30)

    -- Resolve the download directory (mkdir once before invoking subliminal):
    local dir = opts.dir
    if dir == '' then
        local base = filename:gsub('%.%w+$', '')
        if base == '' then base = 'subtitles' end
        dir = (os.getenv('HOME') or '') .. '/.cache/mpv/subtitles/' .. base
    end
    os.execute('mkdir -p ' .. shq(dir))

    -- Build the `subliminal` command:
    local args = { subliminal }
    if opts.debug then
        -- To see `--debug` output start MPV from the terminal!
        args[#args + 1] = '--debug'
    end
    args[#args + 1] = 'download'
    args[#args + 1] = '-f'       -- force overwrite
    args[#args + 1] = '-e'
    args[#args + 1] = 'utf-8'
    args[#args + 1] = '-w'       -- concurrent provider queries
    args[#args + 1] = '8'        -- (v2.7.1: -w/--max-workers, was --pool-size)
    for _, p in ipairs(providers) do
        args[#args + 1] = '-p'
        args[#args + 1] = p
    end
    args[#args + 1] = '-l'
    args[#args + 1] = language[2] -- iso639-1
    args[#args + 1] = '-d'
    args[#args + 1] = dir
    for token in tostring(opts.extra_args):gmatch('%S+') do
        args[#args + 1] = token
    end
    args[#args + 1] = filename    -- basename; subliminal resolves name vs hash

    if opts.debug then
        mp.msg.warn('autosub: running: ' .. table.concat(args, ' '))
    end

    local started = os.time()

    if opts.debug then
        -- All argv entries must be strings; a number here means a config
        -- value was corrupted upstream and mpv would reject the command.
        for i, a in ipairs(args) do
            assert(type(a) == 'string', 'arg ' .. i .. ' is ' .. type(a) ..
                ': ' .. tostring(a))
        end
    end

    local job = mp.command_native_async({
        name = 'subprocess',
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result, error)
        -- Success if subliminal reported a download, OR a fresh subtitle
        -- file appeared in the output directory.
        local downloaded = false
        local out = ''
        if result then
            if result.stdout then out = out .. result.stdout end
            if result.stderr then out = out .. result.stderr end
        end
        local n = tonumber(out:match('Downloaded%s+(%d+)%s+subtitle'))
        if n ~= nil and n > 0 then
            downloaded = true
        elseif result and result.status == 0 and
            newest_subtitle_in(dir, started) ~= nil then
            downloaded = true
        end

        if downloaded then
            -- Subliminal names it <basename-without-ext>.<lang>.srt.
            -- Prefer the expected path; fall back to whatever actually
            -- landed in the download dir.
            local expected = dir .. '/' ..
                filename:gsub('%.%w+$', '') .. '.' .. language[2] .. '.srt'
            local f = io.open(expected, 'r')
            local ok = f ~= nil
            if f then f:close() end
            local path = ok and expected or newest_subtitle_in(dir, started)

            if path then
                -- Add the file explicitly: rescan_external_files only scans
                -- the playing video's directory, but we download into
                -- ~/.cache/mpv/subtitles/<video>/.
                mp.commandv('sub-add', path, 'select')
                -- Keep the language preference; harmless with sub-add.
                mp.set_property('slang', language[2])
                -- Harmless; helps the next-to-video case when autosub_dir is
                -- set to the video's own directory.
                mp.commandv('rescan_external_files')
                log(language[1] .. ' subtitles ready!')
            else
                mp.msg.warn('autosub: downloaded but could not locate ' ..
                            'the subtitle file')
                log(language[1] .. ' subtitles ready!')
            end
        else
            if result and result.killed_by_us then
                mp.msg.warn('Subliminal killed after the ' .. opts.timeout ..
                            's timeout')
            end
            log('No ' .. language[1] .. ' subtitles found')
        end
        done(downloaded)
    end)

    if job then
        -- Wall-clock budget: cancel the job once the timeout elapses.
        -- job.id is cleared by mpv once the command reply has been delivered,
        -- so this is a no-op if the job already finished.
        mp.add_timeout(opts.timeout, function()
            if job.id ~= nil then
                mp.msg.warn('autosub: timeout after ' .. opts.timeout ..
                            's, cancelling subliminal')
                mp.abort_async_command(job)
            end
        end)
        return true
    end

    log('Failed to start subliminal (' .. tostring(error) .. ')')
    done(false)
    return false
end

-- Manually download second language subs by pressing 'n' (see key bindings):
function download_subs2()
    download_subs(languages[2])
end

-- Control function: only download if necessary
function control_downloads()
    -- Make MPV accept external subtitle files with language specifier:
    mp.set_property('sub-auto', 'fuzzy')
    -- Set subtitle language preference:
    if languages[1] then
        mp.set_property('slang', languages[1][2])
    end
    mp.msg.warn('Reactivate external subtitle files:')
    mp.commandv('rescan_external_files')

    local full_path = mp.get_property('path', '')
    local dir, fname = utils.split_path(full_path)
    directory = dir
    filename = fname

    if opts.debug then
        -- Visible in the terminal during autosub_debug=yes:
        mp.msg.warn('autosub: path="' .. full_path ..
                    '" dir="' .. tostring(directory) ..
                    '" file passed to subliminal: "' .. tostring(filename) .. '"')
    end

    if not autosub_allowed() then
        return
    end

    sub_tracks = {}
    for _, track in ipairs(mp.get_property_native('track-list')) do
        if track['type'] == 'sub' then
            sub_tracks[#sub_tracks + 1] = track
        end
    end
    if opts.debug then -- Log subtitle properties to terminal:
        for _, track in ipairs(sub_tracks) do
            mp.msg.warn('Subtitle track', track['id'], ':\n{')
            for k, v in pairs(track) do
                if type(v) == 'string' then v = '"' .. v .. '"' end
                mp.msg.warn('  "' .. k .. '":', v)
            end
            mp.msg.warn('}\n')
        end
    end

    -- Try the languages in order; stop at the first successful download,
    -- or if the right subtitles are already present for a language.
    local function try_next(i)
        if i > #languages then
            log('No subtitles were found')
            return
        end
        local language = languages[i]
        if should_download_subs_in(language) then
            download_subs(language, function(success)
                if success then return end -- Download successful!
                try_next(i + 1)
            end)
        end
        -- else: right subtitles are already present, stop here.
    end
    try_next(1)
end

-- Check if subtitles should be auto-downloaded:
function autosub_allowed()
    local duration = tonumber(mp.get_property('duration'))
    local active_format = mp.get_property('file-format')
    local path = mp.get_property('path', '')

    if not opts.auto then
        mp.msg.warn('Automatic downloading disabled!')
        return false
    elseif duration ~= nil and duration < 900 then
        mp.msg.warn('Video is less than 15 minutes\n' ..
                      '=> NOT auto-downloading subtitles')
        return false
    elseif path:match('^%a[%w+.-]*://') then
        -- Any protocol URL (http(s), av, edl, memory, ...):
        mp.msg.warn('Automatic subtitle downloading is disabled for ' ..
                    'network/protocol streams')
        return false
    elseif active_format ~= nil and active_format:find('^cue') then
        mp.msg.warn('Automatic subtitle downloading is disabled for cue files')
        return false
    else
        local not_allowed = {'aiff', 'ape', 'flac', 'mp3', 'ogg', 'wav', 'wv', 'tta'}

        for _, file_format in pairs(not_allowed) do
            if file_format == active_format then
                mp.msg.warn('Automatic subtitle downloading is disabled for audio files')
                return false
            end
        end

        for _, exclude in pairs(excludes) do
            local escaped_exclude = exclude:gsub('%W','%%%0')
            local excluded = directory:find(escaped_exclude)

            if excluded then
                mp.msg.warn('This path is excluded from auto-downloading subs')
                return false
            end
        end

        for i, include in ipairs(includes) do
            local escaped_include = include:gsub('%W','%%%0')
            local included = directory:find(escaped_include)

            if included then break
            elseif i == #includes then
                mp.msg.warn('This path is not included for auto-downloading subs')
                return false
            end
        end
    end

    return true
end

-- Check if subtitles should be downloaded in this language:
function should_download_subs_in(language)
    for _, track in ipairs(sub_tracks) do
        local subtitles = track['external'] and
          'subtitle file' or 'embedded subtitles'
        local lang = track['lang'] and tostring(track['lang']):lower() or ''
        local title = track['title'] and tostring(track['title']):lower() or ''

        -- Only block the download if this track matches the requested
        -- language (iso639-2, iso639-1, or the code inside the title).
        local matches = lang == language[3] or lang == language[2] or
          (language[3] and title:find(language[3], 1, true))

        if matches then
            if not track['selected'] then
                mp.set_property('sid', track['id'])
                log('Enabled ' .. language[1] .. ' ' .. subtitles .. '!')
            else
                log(language[1] .. ' ' .. subtitles .. ' active')
            end
            mp.msg.warn('=> NOT downloading new subtitles')
            return false -- The right subtitles are already present
        end
    end
    mp.msg.warn('No ' .. language[1] .. ' subtitles were detected\n' ..
                '=> Proceeding to download:')
    return true
end


-- NOTE: 'b' and 'n' are taken by input.conf (mpv-gif.lua, video-unscaled),
-- so the manual triggers live on ctrl+alt+b / ctrl+alt+n instead. Both are
-- also listed in input.conf via `script-binding autosub/download_subs`.
mp.add_key_binding('ctrl+alt+b', 'download_subs', download_subs)
mp.add_key_binding('ctrl+alt+n', 'download_subs2', download_subs2)
mp.register_event('file-loaded', control_downloads)
