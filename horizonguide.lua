addon.name = 'horizonguide';
addon.author = 'valzar';
addon.version = '0.4.8';
addon.desc = 'Offline Horizon wiki browser with manual guide tracking.';
require('common');
local imgui = require('imgui');
local bit = require('bit');

-- Use Windows' native Segoe UI when Ashita exposes custom ImGui font loading.
-- This keeps the addon self-contained (no bundled font files) while replacing
-- ImGui's blockier default font with the same kind of clean UI font used by
-- modern Windows applications. Everything falls back safely if unavailable.
local body_font, bold_font, title_font = nil, nil, nil;
local function add_system_font(filenames, size)
    if not imgui.AddFontFromFileTTF then return nil; end
    local windir = os.getenv('WINDIR') or 'C:\\Windows';
    for _,filename in ipairs(filenames) do
        local path = windir .. '\\Fonts\\' .. filename;
        local exists = false;
        if ashita and ashita.fs and ashita.fs.exists then
            local ok, result = pcall(ashita.fs.exists, path);
            exists = ok and result or false;
        else
            local f = io.open(path, 'rb');
            if f then f:close(); exists = true; end
        end
        if exists then
            local ok, font = pcall(function() return imgui.AddFontFromFileTTF(path, size, nil); end);
            if (not ok) or (not font) then
                ok, font = pcall(function() return imgui.AddFontFromFileTTF(path, size); end);
            end
            if ok and font then return font; end
        end
    end
    return nil;
end

body_font  = add_system_font({'segoeui.ttf', 'tahoma.ttf', 'arial.ttf'}, 15.0);
bold_font  = add_system_font({'seguisb.ttf', 'segoeuib.ttf', 'tahomabd.ttf', 'arialbd.ttf'}, 15.0);
title_font = add_system_font({'seguisb.ttf', 'segoeuib.ttf', 'tahomabd.ttf', 'arialbd.ttf'}, 20.0);

local function push_font(font, size)
    if not font then return false; end
    -- Ashita 4.3 / newer ImGui builds take a size argument; older builds only
    -- take the font pointer. Support both so the addon remains portable.
    local ok = pcall(imgui.PushFont, font, size or 0.0);
    if not ok then ok = pcall(imgui.PushFont, font); end
    return ok;
end

local function pop_font(pushed)
    if pushed then imgui.PopFont(); end
end
-- ImGui 1.90+ replaces the legacy border boolean with numeric child flags.
-- Ashita exports these constants through require('imgui').
local function begin_child(id, size)
    local border = ImGuiChildFlags_Borders or ImGuiChildFlags_Border;
    if border ~= nil or (tonumber(IMGUI_VERSION_NUM) or 0) >= 19000 then
        return imgui.BeginChild(id, size, border or 1, 0);
    end
    return imgui.BeginChild(id, size, true, 0);
end
local settings = require('settings');
local catalog = require('catalog');
local profession_data = require('professions');
local skill_range_data = require('skillranges');
local state = settings.load(T{ profiles = T{} });
local visible, tracker = { true }, { true };
local query, show_completed, show_planned = { '' }, { false }, { false };
local filter = 'all';
local job_choice = 'All jobs';
local job_names, job_seen = {}, {};
for _,q in ipairs(catalog) do
    for _,job in ipairs(q.jobs or {}) do
        if not job_seen[job] then job_names[#job_names + 1]=job; job_seen[job]=true; end
    end
end
table.sort(job_names);
local function matches_job(q)
    if #(q.jobs or {}) == 0 then return false; end
    if job_choice == 'All jobs' then return true; end
    for _,job in ipairs(q.jobs) do if job == job_choice then return true; end end
    return false;
end
local zone_choice, zone_mode = 'All zones', 'Starts here';
local follow_zone = { false };
local zone_search = { '' };
local zone_names, zone_seen, zone_lookup = {}, {}, {};
local function zone_key(value)
    return (value or ''):lower():gsub('_',' '):gsub('%s+',' '):match('^%s*(.-)%s*$');
end
for _,q in ipairs(catalog) do
    for _,field in ipairs({'start_zones','step_zones'}) do
        for _,zone in ipairs(q[field] or {}) do
            if not zone_seen[zone] then
                zone_seen[zone]=true; zone_names[#zone_names+1]=zone;
                zone_lookup[zone_key(zone)]=zone;
            end
        end
    end
end
table.sort(zone_names);
local function current_zone(p)
    if not p then return nil; end
    local ok,name=pcall(function()
        local id=AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        if type(id)~='number' or id<=0 then return nil; end
        return AshitaCore:GetResourceManager():GetString('zones.names',id);
    end);
    if not ok or type(name)~='string' or name=='' or name:lower()=='unknown' then return nil; end
    return zone_lookup[zone_key(name)] or name;
end
local function matches_zone(q,zone)
    if zone=='All zones' then return true; end
    if not zone then return false; end
    local zones=zone_mode=='Starts here' and q.start_zones or q.step_zones;
    for _,name in ipairs(zones or {}) do if zone_key(name)==zone_key(zone) then return true; end end
    return false;
end
local show_panel = { false };
local show_all_blocks = { false };
-- Focused navigation hubs. Starter mode is saved per character; Jobs and
-- Professions are browsing modes and do not alter game state.
local hub_mode = 'all';
local selected_job_hub = '';
local selected_profession = 'Alchemy';
local selected_profession_range = '0-10';
local profession_names = { 'Alchemy','Bonecraft','Clothcraft','Cooking','Fishing','Goldsmithing','Leathercraft','Smithing','Woodworking' };
local profession_ranges = { '0-10','11-20','21-30','31-40','41-50','51-60','61-70','71-80','81-90','91-100' };
local pending_size = nil;
local details_selection = nil;
local selected = nil;
local catalog_index = {};
for i,q in ipairs(catalog) do catalog_index[q.id]=i; end
local function open_entry(id)
    if not catalog_index[id] then return; end
    visible[1]=true; selected=catalog_index[id]; query[1]=''; filter='all';
    follow_zone[1]=false; zone_choice='All zones';
end
local title_dragged = false;
local filtered, cache_key = {}, nil;
local searchable = {};
for i,q in ipairs(catalog) do
    local terms = q.title .. ' ' .. q.requirements .. ' ' .. q.group .. ' ' .. table.concat(q.jobs or {}, ' ');
    for _,s in ipairs(q.steps) do
        terms = terms .. ' ' .. s.zone .. ' ' .. s.npc;
        if q.kind=='guide' then terms=terms .. ' ' .. s.text; end
    end
    searchable[i] = terms:lower();
end
local function save()
    cache_key = nil;
    settings.save();
end
settings.register('settings', 'horizonguide_settings', function(s)
    if s ~= nil then state = s; end
    cache_key = nil;
end);
local function profile()
    local ok,id,n = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party:GetMemberServerId(0), party:GetMemberName(0);
    end);
    if not ok or not id or id == 0 or not n or n == '' then return nil, 'No character detected'; end
    local key = tostring(id) .. ':' .. n;
    state.profiles = state.profiles or {};
    if not state.profiles[key] then state.profiles[key] = { progress = {}, completed = {}, started = {}, tracked = '', start_nation = '', starter_mode = false }; end
    local p = state.profiles[key];
    -- Backward compatibility for profiles created before v0.3.3.
    p.progress = p.progress or {};
    p.completed = p.completed or {};
    p.started = p.started or {};
    p.tracked = p.tracked or '';
    p.start_nation = p.start_nation or '';
    if p.starter_mode == nil then p.starter_mode = false; end
    return p, n;
end
local function linked_done(s,p)
    if not p then return false; end
    if s.link_id and p.completed[s.link_id] then return true; end
    for _,id in ipairs(s.skip_if_any or {}) do if p.completed[id] then return true; end end
    return false;
end

-- MediaWiki imports sometimes turn section labels such as "Windurst",
-- "BCNM Fight", or "Inner Horutoto Ruins" into their own empty progress
-- blocks. They are useful context, but they are not player actions. Keep the
-- raw catalog indices intact for save compatibility while skipping these
-- structural rows in mission progress.
local action_words = {
    accept=true, approach=true, ask=true, board=true, bring=true, buy=true, check=true,
    choose=true, click=true, collect=true, continue=true, cross=true, defeat=true,
    deliver=true, dig=true, drop=true, enter=true, equip=true, examine=true, fight=true,
    find=true, fish=true, follow=true, give=true, go=true, hand=true, head=true,
    inspect=true, investigate=true, kill=true, leave=true, look=true, make=true,
    meet=true, mine=true, obtain=true, open=true, pay=true, pick=true, proceed=true,
    purchase=true, read=true, ['repeat']=true, report=true, ['return']=true, search=true,
    select=true, show=true, sneak=true, speak=true, take=true, talk=true, touch=true,
    trade=true, travel=true, unlock=true, use=true, visit=true, wait=true, walk=true, win=true,
    zone=true, note=true, warning=true, remember=true, once=true, after=true, before=true,
    buff=true, buffs=true, you=true, your=true, player=true, players=true, everyone=true,
    party=true, all=true, each=true, have=true, keep=true, be=true,
};
local function trim_text(s) return (s or ''):match('^%s*(.-)%s*$'); end
local function is_structural_note(s)
    local text=trim_text(s and s.text);
    local lower=text:lower();
    return lower:match('^note%s*:')~=nil or lower:match('^warning%s*:')~=nil;
end
local function is_structural_step(q,s)
    if not q or (q.kind~='mission' and q.kind~='quest') or not s then return false; end
    if trim_text(s.zone)~='' or trim_text(s.grid)~='' or trim_text(s.npc)~='' then return false; end
    local text=trim_text(s.text);
    if text=='' then return false; end
    -- Notes and short MediaWiki section labels are context, not objectives.
    if is_structural_note(s) then return true; end
    if text:find('\n',1,true) or #text>72 then return false; end
    local lower=text:lower();
    local first=lower:match('^([%a]+)');
    if first and action_words[first] then return false; end
    if lower:find(' is ',1,true) or lower:find(' are ',1,true) or lower:find(' will ',1,true) then return false; end
    if text:match('[%.%!%?%;:]$') then return false; end
    return true;
end

-- Sections that are useful reference material but should not inflate manual
-- progress. Their bullets are shown below the walkthrough in a notes panel.
local supplemental_sections = {
    ['notes']=true,
    ['additional notes']=true,
    ['enemy notes']=true,
    ['travel notes']=true,
    ['general notes on escort quests']=true,
    ['the fight']=true,
    ['strategies']=true,
    ['strategy']=true,
    ['strategy tips']=true,
    ['battle mechanics']=true,
    ['fight notes']=true,
    ['battlefield notes']=true,
    ['testimonials']=true,
    ['testimony']=true,
    ['tips']=true,
    ['see also']=true,
    ['rewards']=true,
    ['repeat completions']=true,
    ['if the mission fails']=true,
    ['examples']=true,
};

local function is_supplemental_heading(text)
    local lower=trim_text(text):lower();
    if supplemental_sections[lower] then return true; end
    if lower:match('^notes%s*[-:]') or lower:match('^additional notes%s*[-:]') then return true; end
    if lower:match('notes$') and (lower:find('enemy',1,true) or lower:find('travel',1,true) or lower:find('battle',1,true) or lower:find('fight',1,true)) then return true; end
    return false;
end

-- Dated player reports and anecdotal "worked for me" comments occasionally
-- appear as bullets in walkthroughs. Only classify a row when it looks clearly
-- like testimony and does not itself begin with an action verb.
local function is_testimony_step(q,s)
    if not q or (q.kind~='quest' and q.kind~='mission') or not s then return false; end
    if trim_text(s.zone)~='' or trim_text(s.grid)~='' or trim_text(s.npc)~='' then return false; end
    local text=trim_text(s.text);
    if text=='' then return false; end
    local lower=text:lower();
    if lower:match('^optional') then return false; end
    local first=lower:match('^([%a]+)');
    if first and action_words[first] then return false; end

    local starts_date =
        lower:match('^%d%d?/%d%d?/%d%d%d%d%s*[-:]') or
        lower:match('^%d%d?/%d%d?/%d%d%s*[-:]') or
        lower:match('^%d%d?%s+%a+%s+20%d%d%s*[-:]') or
        lower:match('^%(%d%d%d%d[%-%/]');
    local anecdote =
        lower:match('^confirming ') or lower:match('^multiple ') or lower:match('^sneak%+') or
        lower:match('^holding one ') or lower:match('^recently tested') or lower:match('^tested ') or
        lower:match('^soloed ') or lower:match('^duoed ') or lower:match('^trioed ');
    return starts_date~=nil or anecdote~=nil;
end

-- Return the nearest MediaWiki subsection heading that applies to step j.
local function section_before_index(q,j)
    if not q or j<=1 then return ''; end
    local k=j-1;
    while k>=1 do
        local s=q.steps[k];
        if is_structural_step(q,s) and not is_structural_note(s) then
            return trim_text(s.text);
        end
        k=k-1;
    end
    return '';
end

local function is_supplemental_index(q,j)
    local s=q and q.steps and q.steps[j];
    if not s then return false; end
    if is_testimony_step(q,s) then return true; end
    local section=section_before_index(q,j);
    return section~='' and is_supplemental_heading(section);
end

local function is_non_actionable_index(q,j)
    local s=q and q.steps and q.steps[j];
    if not s then return false; end
    return is_structural_step(q,s) or is_supplemental_index(q,j);
end

local function supplemental_steps(q)
    local out={};
    if not q then return out; end
    for i,s in ipairs(q.steps or {}) do
        if is_supplemental_index(q,i) then
            local section=section_before_index(q,i);
            if is_testimony_step(q,s) and section=='' then section='Community testimony'; end
            out[#out+1]={ index=i, step=s, section=section };
        end
    end
    return out;
end

local function next_actionable_index(q,n)
    while n<=#q.steps and is_non_actionable_index(q,n) do n=n+1; end
    return n;
end
local function previous_actionable_index(q,n)
    local j=math.min(n-1,#q.steps);
    while j>1 and is_non_actionable_index(q,j) do j=j-1; end
    if j==1 and is_non_actionable_index(q,j) then return 1; end
    return math.max(1,j);
end
local function actionable_step_count(q)
    local count=0;
    for i=1,#(q.steps or {}) do if not is_non_actionable_index(q,i) then count=count+1; end end
    return count;
end
local function actionable_step_number(q,j)
    local count=0;
    for i=1,math.min(j,#q.steps) do if not is_non_actionable_index(q,i) then count=count+1; end end
    return count;
end
local function section_heading_before(q,j)
    if not q or j<=1 then return ''; end
    local labels={};
    local k=j-1;
    while k>=1 and is_structural_step(q,q.steps[k]) do
        if not is_structural_note(q.steps[k]) and not is_supplemental_heading(q.steps[k].text) then
            table.insert(labels,1,trim_text(q.steps[k].text));
        end
        k=k-1;
    end
    return table.concat(labels,' / ');
end
local function structural_notes_before(q,j)
    local notes={};
    local k=j-1;
    while k>=1 and is_structural_step(q,q.steps[k]) do
        if is_structural_note(q.steps[k]) then table.insert(notes,1,trim_text(q.steps[k].text)); end
        k=k-1;
    end
    return notes;
end

local function step_index(q,p)
    local n=math.max(1, math.min(#q.steps + 1, tonumber(p and p.progress[q.id]) or 1));
    n=next_actionable_index(q,n);
    if q.kind=='path' then
        while n<=#q.steps and linked_done(q.steps[n],p) do n=n+1; end
    end
    return n;
end
-- Many imported wiki pages contain leftover template and table fragments that
-- are useful to the importer but ugly in-game. Clean them at display time so
-- raw wiki markup does not leak into the addon UI.
local function sanitize_display_text(text)
    local s = tostring(text or '');
    s = s:gsub('\r\n', '\n'):gsub('\r', '\n');
    -- Remove multiline template fragments such as [Template Quest/Description: ...].
    s = s:gsub('%[Template.-%]', '');
    s = s:gsub('%[TEMPLATE.-%]', '');
    -- Convert MediaWiki links [[Page|Label]] / [[Page]] to plain text labels.
    s = s:gsub('%[%[([^%]|]+)|([^%]]+)%]%]', '%2');
    s = s:gsub('%[%[([^%]]+)%]%]', '%1');

    local out = {};
    local last_blank = true;
    for raw in (s .. '\n'):gmatch('(.-)\n') do
        local line = raw:gsub('^%s+', ''):gsub('%s+$', '');
        line = line:gsub('%[Template.-%]', '');
        line = line:gsub('%[%[([^%]|]+)|([^%]]+)%]%]', '%2');
        line = line:gsub('%[%[([^%]]+)%]%]', '%1');

        local markup_only =
            line:match('^/?summary%s*=') or
            line:match('^client%s*=') or
            line:match('^orders%s*=') or
            line:match('^%{%|') or
            line:match('^|%-') or
            line == '|}' or line == '||' or
            line:match('^|') or line:match('^!') or
            line:match('^width%s*=') or line:match('^valign%s*=');

        if not markup_only then
            line = line:gsub('%{%{.-%}%}', '');
            line = line:gsub('&nbsp;', ' ');
            line = line:gsub('%s%s+', ' ');
            line = line:gsub('^%s+', ''):gsub('%s+$', '');
            if line == '' then
                if not last_blank then out[#out + 1] = ''; end
                last_blank = true;
            else
                out[#out + 1] = line;
                last_blank = false;
            end
        end
    end
    while #out > 0 and out[1] == '' do table.remove(out, 1); end
    while #out > 0 and out[#out] == '' do table.remove(out, #out); end
    return table.concat(out, '\n');
end

local function wrapped(s)
    local clean = sanitize_display_text(s);
    if clean ~= '' then imgui.TextWrapped(clean); end
end
local gold = { 0.95, 0.78, 0.43, 1 };
local function heading(text)
    local pushed = push_font(bold_font, 15.0);
    imgui.TextColored(gold, text);
    pop_font(pushed);
    imgui.Spacing();
end
local function title_text(text)
    local pushed = push_font(title_font, 20.0);
    imgui.TextWrapped(text);
    pop_font(pushed);
end
local function push_theme()
    local colors = {
        {ImGuiCol_WindowBg, {0.055,0.09,0.105,0.98}},
        {ImGuiCol_ChildBg, {0.065,0.105,0.12,1}},
        {ImGuiCol_Text, {0.89,0.93,0.94,1}},
        {ImGuiCol_Border, {0.18,0.28,0.32,1}},
        {ImGuiCol_FrameBg, {0.10,0.16,0.19,1}},
        {ImGuiCol_Button, {0.13,0.21,0.25,1}},
        {ImGuiCol_ButtonHovered, {0.24,0.35,0.39,1}},
        {ImGuiCol_ButtonActive, {0.36,0.40,0.30,1}},
        {ImGuiCol_Header, {0.24,0.30,0.25,1}},
        {ImGuiCol_HeaderHovered, {0.19,0.29,0.32,1}},
        {ImGuiCol_HeaderActive, {0.30,0.37,0.30,1}},
        {ImGuiCol_TitleBg, {0.055,0.09,0.105,1}},
        {ImGuiCol_TitleBgActive, {0.10,0.16,0.19,1}},
        {ImGuiCol_CheckMark, gold},
    };
    for _,c in ipairs(colors) do imgui.PushStyleColor(c[1], c[2]); end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {12,12});
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {6,3});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {6,6});
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
end
local function show_step(s)
    wrapped(s.text);
    if s.zone ~= '' then wrapped('Zone: ' .. s.zone); end
    if s.grid ~= '' then wrapped('Map square: ' .. s.grid); end
end

-- Imported wiki blocks can contain several dense paragraphs. Render them one line
-- at a time with breathing room so long crafting / mission notes remain readable.
local function show_step_roomy(s)
    local first = true;
    local text = sanitize_display_text(s.text or '');
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local clean = line:match('^%s*(.-)%s*$');
        if clean == '' then
            imgui.Spacing();
        else
            if first and (#clean <= 80 or clean:match('^Level%s+%d+')) then
                imgui.TextColored({0.92,0.95,0.96,1}, clean);
            else
                imgui.TextWrapped(clean);
            end
            imgui.Spacing();
            first = false;
        end
    end
    if s.zone ~= '' then
        imgui.TextColored({0.60,0.73,0.79,1}, 'Zone: ' .. s.zone);
    end
    if s.grid ~= '' then
        imgui.TextColored({0.60,0.73,0.79,1}, 'Map square: ' .. s.grid);
    end
end

-- Wiki pages in the Reference guides group are informational pages, not quests.
-- They should read like an article/reference sheet instead of pretending every
-- imported section is a trackable objective with Start here / Step done controls.
local function is_reference_guide(q)
    if not q then return false; end
    return q.kind == 'guide' or (q.group or ''):lower() == 'reference guides';
end

local function clean_reference_line(line)
    local clean=sanitize_display_text(line or ''):match('^%s*(.-)%s*$');
    if clean == '' then return ''; end
    -- Strip common MediaWiki/template fragments that are useful to the importer
    -- but look broken when shown directly to a player.
    if clean:match('^%[Template%s+') or clean:match('^%[Template%s*guide') then return nil; end
    if clean:match('^%{%|') or clean:match('^|%-') or clean == '|}' or clean == '||' then return nil; end
    return clean;
end

local function reference_block_parts(text)
    local lines={};
    for line in ((text or '') .. '\n'):gmatch('(.-)\n') do
        local clean=clean_reference_line(line);
        if clean ~= nil then lines[#lines+1]=clean; end
    end
    while #lines>0 and lines[1]=='' do table.remove(lines,1); end
    while #lines>0 and lines[#lines]=='' do table.remove(lines,#lines); end
    if #lines==0 then return nil, lines; end

    local first=lines[1];
    local lower=first:lower();
    local heading_like = #first <= 72 and (
        lower=='introduction' or lower=='overview' or lower=='notes' or lower=='note' or
        first:match('^Levels?%s+%d') or first:match('^Level%s+%d') or
        first:match('^%d+%s*%-%s*%d+%s*$') or
        first:match('^[%u][%u%s/&:%-]+$')
    );
    if heading_like then
        table.remove(lines,1);
        while #lines>0 and lines[1]=='' do table.remove(lines,1); end
        return first, lines;
    end
    return nil, lines;
end

local function render_reference_line(q, line)
    if line == '' then imgui.Spacing(); return; end

    -- This page is a lookup table: level, zone, NM, guaranteed drop. Present
    -- each record as a compact two-line entry instead of a fake quest step.
    if q.id == 'wiki_19869' then
        local level, zone, nm, drop = line:match('^([%d%-+]+)%s+(.+)%s+%-%s+(.+)%s+%-%s+(.+)$');
        if level and zone and nm and drop then
            local pushed=push_font(bold_font, 15.0);
            imgui.TextWrapped('Lv. ' .. level .. '  ' .. nm);
            pop_font(pushed);
            imgui.TextColored({0.61,0.75,0.80,1}, zone);
            imgui.SameLine();
            imgui.TextWrapped('  -  ' .. drop);
            imgui.Spacing();
            return;
        end
    end
    wrapped(line);
end

local function render_reference_guide(q)
    heading('REFERENCE GUIDE');
    wrapped('Browse this page as reference material. It is not treated as a quest or step-by-step checklist.');
    imgui.Spacing();

    if #q.steps == 0 then
        wrapped('No imported reference sections are available for this entry.');
        return;
    end

    for j,s in ipairs(q.steps) do
        local section, lines=reference_block_parts(s.text);
        if section then
            local pushed=push_font(bold_font, 15.0);
            imgui.TextColored(gold, section);
            pop_font(pushed);
            imgui.Spacing();
        end
        for _,line in ipairs(lines) do render_reference_line(q,line); end
        if s.zone ~= '' then imgui.TextColored({0.60,0.73,0.79,1}, 'Zone: ' .. s.zone); end
        if s.grid ~= '' then imgui.TextColored({0.60,0.73,0.79,1}, 'Map square: ' .. s.grid); end
        if j < #q.steps then imgui.Spacing(); imgui.Separator(); imgui.Spacing(); end
    end
end

local function guide_started(q,p)
    if not p then return false; end
    if p.started and p.started[q.id] then return true; end
    return (tonumber(p.progress and p.progress[q.id]) or 1) > 1;
end

local function mark_started(q,p)
    if not p then return; end
    p.started = p.started or {};
    p.started[q.id] = true;
end

-- Guide cards used to be a fixed 300px tall, which left a large empty box for
-- short objectives. Estimate the height from the actual text so short blocks
-- stay compact while long imported wiki notes still get the room they need.
local function estimate_card_height(q,p,j,s,already_done)
    local chars_per_line = 92;
    local ok_width, window_width = pcall(imgui.GetWindowWidth);
    if ok_width and type(window_width) == 'number' and window_width > 200 then
        chars_per_line = math.max(42, math.floor((window_width - 54) / 7.4));
    end
    local visual_lines, blank_lines = 0, 0;
    local text = sanitize_display_text((s and s.text) or '');
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local clean = line:match('^%s*(.-)%s*$');
        if clean == '' then
            blank_lines = blank_lines + 1;
        else
            visual_lines = visual_lines + math.max(1, math.ceil(#clean / chars_per_line));
        end
    end
    if s and s.zone ~= '' then visual_lines = visual_lines + 1; end
    if s and s.grid ~= '' then visual_lines = visual_lines + 1; end
    if already_done then visual_lines = math.max(visual_lines, 1); end

    local height = 56 + (visual_lines * 19) + (blank_lines * 8);
    if s and s.link_id then height = height + 32; end
    if p and not already_done and not guide_started(q,p) then height = height + 30; end

    -- Keep tiny cards readable, but never force a short objective into a giant
    -- mostly-empty panel. Very long wiki blocks get an internal scrollbar.
    local min_height = (p and not already_done and not guide_started(q,p)) and 132 or 108;
    return math.max(min_height, math.min(height, 520));
end

local function accent_button(label)
    imgui.PushStyleColor(ImGuiCol_Button, gold);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.98,0.84,0.52,1});
    imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.82,0.66,0.34,1});
    imgui.PushStyleColor(ImGuiCol_Text, {0.055,0.09,0.105,1});
    local pressed = imgui.Button(label);
    imgui.PopStyleColor(4);
    return pressed;
end

local function controls(q,p)
    if not p then wrapped('Log in to save manual progress.'); return; end
    local n = step_index(q,p);
    if n <= #q.steps then
        if accent_button('Step done##' .. q.id) then mark_started(q,p); p.progress[q.id] = next_actionable_index(q,n + 1); save(); end
        imgui.SameLine();
    else
        wrapped('Guide steps finished. Quest completion has not been verified.');
    end
    if imgui.Button('Previous##' .. q.id) then p.progress[q.id] = previous_actionable_index(q,n); save(); end
end

local function render_step_card(q,p,j,s)
    local already_done=q.kind=='path' and linked_done(s,p);
    local card_height=estimate_card_height(q,p,j,s,already_done);
    local section=section_heading_before(q,j);
    local context_notes=structural_notes_before(q,j);
    if section~='' then card_height=math.min(card_height+24,544); end
    if #context_notes>0 then card_height=math.min(card_height+(#context_notes*42),544); end
    imgui.PushStyleColor(ImGuiCol_Border, {0.78,0.62,0.28,1});
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 6);
    if begin_child('guide_card##' .. q.id .. '_' .. j, {0, card_height}) then
        local current=step_index(q,p);
        local display_num=actionable_step_number(q,j);
        local display_total=actionable_step_count(q);
        heading((j < current and 'DONE - ' or j == current and 'CURRENT - ' or 'STEP ') .. display_num .. ' / ' .. display_total);
        if section~='' then
            imgui.TextColored({0.66,0.80,0.84,1}, section);
            imgui.Spacing();
        end
        for _,note in ipairs(context_notes) do
            imgui.TextColored({0.92,0.76,0.42,1}, 'NOTE');
            wrapped(note:gsub('^[Nn][Oo][Tt][Ee]%s*:%s*',''):gsub('^[Ww][Aa][Rr][Nn][Ii][Nn][Gg]%s*:%s*',''));
            imgui.Spacing();
        end
        if already_done then
            wrapped('Already marked complete - skipped.');
        else
            show_step_roomy(s);
            if s.link_id then
                imgui.Spacing();
                if imgui.Button('Open ' .. s.link_title .. '##link_' .. q.id .. '_' .. j) then
                    open_entry(s.link_id); cache_key=nil;
                end
            end
        end
        if p and not already_done and not guide_started(q,p) then
            imgui.Spacing();
            if imgui.SmallButton('Start here##' .. q.id .. '_' .. j) then
                p.progress[q.id]=j;
                mark_started(q,p);
                save();
            end
        end
    end
    imgui.EndChild();
    imgui.PopStyleVar();
    imgui.PopStyleColor();
end
local function refresh(p, char, active_zone)
    local key = query[1] .. ':' .. filter .. ':' .. tostring(show_completed[1]) .. ':' .. tostring(show_planned[1]) .. ':' .. char .. ':' .. job_choice .. ':' .. zone_mode .. ':' .. tostring(active_zone);
    if key == cache_key then return; end
    cache_key = key; filtered = {};
    for i,q in ipairs(catalog) do
        local complete = p and p.completed[q.id];
        if (show_completed[1] or not complete) and (show_planned[1] or q.availability ~= 'unavailable')
            and matches_zone(q,active_zone) and (filter == 'all' or q.kind == filter or (filter == 'job' and matches_job(q))) and searchable[i]:find(query[1]:lower(),1,true) then
            filtered[#filtered + 1] = i;
        end
    end
    local found = false;
    for _,i in ipairs(filtered) do if i == selected then found = true; break; end end
    if not found then selected = filtered[1]; end
end
-- Jobs / professions hubs --------------------------------------------------
local job_hub_aliases = {
    ['Warrior (WAR)']={'warrior','war'}, ['Monk (MNK)']={'monk','mnk'},
    ['White Mage (WHM)']={'white mage','whm'}, ['Black Mage (BLM)']={'black mage','blm'},
    ['Red Mage (RDM)']={'red mage','rdm'}, ['Thief (THF)']={'thief','thf'},
    ['Paladin (PLD)']={'paladin','pld'}, ['Dark Knight (DRK)']={'dark knight','drk'},
    ['Beastmaster (BST)']={'beastmaster','bst'}, ['Bard (BRD)']={'bard','brd'},
    ['Ranger (RNG)']={'ranger','rng'}, ['Samurai (SAM)']={'samurai','sam'},
    ['Ninja (NIN)']={'ninja','nin'}, ['Dragoon (DRG)']={'dragoon','drg'},
    ['Summoner (SMN)']={'summoner','smn'}, ['Blue Mage (BLU)']={'blue mage','blu'},
    ['Corsair (COR)']={'corsair','cor'}, ['Puppetmaster (PUP)']={'puppetmaster','pup'},
};
local job_extra_guides = {
    ['Thief (THF)']={['sata']=true},
    ['White Mage (WHM)']={["sushomi's beginners guide to healing"]=true},
    ['Black Mage (BLM)']={['manaburn camps']=true},
};

local function entry_has_job(q,job)
    for _,name in ipairs(q.jobs or {}) do if name==job then return true; end end
    return false;
end

local function job_guide_matches(q,job)
    if not q or q.kind~='guide' then return false; end
    local hay=((q.title or '') .. ' ' .. (q.summary or '') .. ' ' .. (q.requirements or '')):lower();
    local extras=job_extra_guides[job] or {};
    if extras[(q.title or ''):lower()] then return true; end
    local aliases=job_hub_aliases[job] or {};
    for _,alias in ipairs(aliases) do
        alias=alias:lower();
        if #alias>3 then
            if hay:find(alias,1,true) then return true; end
        else
            if hay:find('%f[%w]' .. alias .. '%f[%W]') then return true; end
        end
    end
    return false;
end

local function job_entries(job,kind)
    local out={};
    for i,q in ipairs(catalog) do
        if kind=='guide' then
            if job_guide_matches(q,job) then out[#out+1]=i; end
        elseif q.kind==kind and entry_has_job(q,job) then
            out[#out+1]=i;
        end
    end
    table.sort(out,function(a,b) return catalog[a].title:lower()<catalog[b].title:lower(); end);
    return out;
end

local function profession_guides(name)
    local out={};
    local needle=(name or ''):lower();
    for i,q in ipairs(catalog) do
        if q.kind=='guide' then
            local title=(q.title or ''):lower();
            if title:find(needle,1,true) or title=='beginner how-to guide' then out[#out+1]=i; end
        end
    end
    table.sort(out,function(a,b) return catalog[a].title:lower()<catalog[b].title:lower(); end);
    return out;
end

local function hub_selectable(i,p,prefix)
    local q=catalog[i]; if not q then return; end
    local label=(p and p.completed[q.id] and '[Done] ' or '') .. q.title;
    if imgui.Selectable(label .. '##' .. (prefix or 'hub') .. '_' .. q.id,selected==i) then
        selected=i; details_selection=nil;
    end
end

local function render_jobs_sidebar(p)
    heading('JOBS');
    if selected_job_hub=='' then
        wrapped('Choose a job to see its unlock, artifact and other job-related quests plus guides.');
        imgui.Separator();
        for _,job in ipairs(job_names) do
            if imgui.Selectable(job .. '##job_hub_pick',false) then
                selected_job_hub=job; selected=nil; details_selection=nil;
            end
        end
        return;
    end

    local pushed=push_font(bold_font,15.0); imgui.TextWrapped(selected_job_hub); pop_font(pushed);
    if imgui.SmallButton('Change job') then selected_job_hub=''; selected=nil; details_selection=nil; end
    imgui.SameLine();
    if imgui.SmallButton('Browse all##jobs') then hub_mode='all'; selected_job_hub=''; end
    imgui.Separator();

    local quests=job_entries(selected_job_hub,'quest');
    local missions=job_entries(selected_job_hub,'mission');
    local guides=job_entries(selected_job_hub,'guide');
    if imgui.CollapsingHeader('QUESTS (' .. #quests .. ')##jobquests') then
        imgui.Indent(8); for _,i in ipairs(quests) do hub_selectable(i,p,'jobquest'); end; imgui.Unindent(8);
    end
    if #missions>0 and imgui.CollapsingHeader('MISSIONS (' .. #missions .. ')##jobmissions') then
        imgui.Indent(8); for _,i in ipairs(missions) do hub_selectable(i,p,'jobmission'); end; imgui.Unindent(8);
    end
    if imgui.CollapsingHeader('GUIDES (' .. #guides .. ')##jobguides') then
        imgui.Indent(8); for _,i in ipairs(guides) do hub_selectable(i,p,'jobguide'); end; imgui.Unindent(8);
    end
end

local function profession_range_count(name,range)
    local by_prof=skill_range_data[name];
    local data=by_prof and by_prof[range];
    return data and #(data.entries or {}) or 0;
end

local function render_profession_sidebar(p)
    heading('PROFESSIONS');
    local pdata=profession_data[selected_profession];
    local pushed=push_font(bold_font,15.0); imgui.TextWrapped(selected_profession); pop_font(pushed);
    wrapped('Browse the complete skill brackets for this profession, then open separate community guides when you want a recommended leveling route.');
    if imgui.SmallButton('Change profession') then imgui.OpenPopup('profession_pick'); end
    if imgui.BeginPopup('profession_pick') then
        for _,name in ipairs(profession_names) do
            if imgui.Selectable(name .. '##profession',selected_profession==name) then
                selected_profession=name; selected_profession_range='0-10'; selected=nil; details_selection=nil; imgui.CloseCurrentPopup();
            end
        end
        imgui.EndPopup();
    end
    imgui.SameLine();
    if imgui.SmallButton('Browse all##professions') then hub_mode='all'; end
    if pdata then
        if imgui.SmallButton('Profession wiki') then ashita.misc.open_url(pdata.page_url); end
        imgui.SameLine();
        if imgui.SmallButton(selected_profession=='Fishing' and 'All Fish' or 'All Recipes') then ashita.misc.open_url(pdata.recipes_url); end
    end
    imgui.Separator();

    if imgui.CollapsingHeader('SKILL RANGE##profession_skill_range') then
        imgui.Indent(8);
        for _,range in ipairs(profession_ranges) do
            local count=profession_range_count(selected_profession,range);
            local label=range .. (count>0 and ('  (' .. count .. ')') or '');
            if imgui.Selectable(label .. '##prof_range_' .. range,selected==nil and selected_profession_range==range) then
                selected_profession_range=range; selected=nil; details_selection=nil;
            end
        end
        imgui.Unindent(8);
    end

    local guides=profession_guides(selected_profession);
    if imgui.CollapsingHeader('GUIDES (' .. #guides .. ')##profession_guides') then
        imgui.Indent(8);
        for _,i in ipairs(guides) do hub_selectable(i,p,'professionguide'); end
        imgui.Unindent(8);
    end
end

local function skill_field(label,value)
    if not value or value=='' then return; end
    imgui.TextColored({0.60,0.73,0.79,1},label);
    if #value < 100 then imgui.SameLine(); end
    wrapped(value);
    if #value >= 100 then imgui.Spacing(); end
end

local function render_skill_range_entries(name,range,data)
    local entries=data and data.entries or {};
    if #entries==0 then return false; end

    heading(name=='Fishing' and 'AVAILABLE FISH' or 'AVAILABLE RECIPES');
    wrapped(name=='Fishing' and 'Grouped by fishing skill cap, not minimum catch level. Expand a catch for locations, bait and rod information.' or 'Grouped by crafting skill cap. Expand a recipe for crystal, ingredients and requirements.');
    wrapped('Wiki reference: availability and details are not verified in game.');
    imgui.Spacing();

    for i,e in ipairs(entries) do
        local prefix='Cap ' .. tostring(e.cap or e.level or '?');
        local label=prefix .. '  -  ' .. (e.name or 'Unknown');
        if imgui.CollapsingHeader(label .. '##skill_' .. name .. '_' .. range .. '_' .. i) then
            imgui.Indent(12);
            if data.kind=='fish' then
                skill_field('Location:',e.location);
                skill_field('Bait:',e.bait);
                skill_field('Rods:',e.rods);
                skill_field('Note:',e.notes);
            else
                skill_field('Crystal:',e.crystal);
                skill_field('Ingredients:',e.ingredients);
                skill_field('Requirements:',e.extra);
                skill_field('Note:',e.notes);
                if e.hq and e.hq~='' and imgui.CollapsingHeader('High-quality results##hq_' .. name .. '_' .. range .. '_' .. i) then
                    wrapped(e.hq);
                end
            end
            if e.source and imgui.SmallButton('Item wiki##item_' .. name .. '_' .. range .. '_' .. i) then
                ashita.misc.open_url(e.source);
            end
            imgui.Unindent(12);
            imgui.Spacing();
        end
    end
    return true;
end


local function render_inline_range_blocks(blocks)
    if not blocks or #blocks==0 then return false; end
    heading('SKILL RANGE');
    wrapped('Everything for this selected skill bracket is listed directly below.');
    imgui.Spacing();
    for i,block in ipairs(blocks) do
        local body=block or '';
        -- The profession page already shows the selected skill bracket, so do not
        -- repeat imported headings such as "Level 40 - 50" above the same content.
        local first,rest=body:match('^%s*([^\n]+)\n(.*)$');
        if first and first:match('^[Ll]evel%s+%d+%s*[%-%~]%s*%d+') then
            body=rest or '';
        end
        show_step_roomy({ text = body, zone = '', grid = '' });
        if i < #blocks then
            imgui.Separator();
            imgui.Spacing();
        end
    end
    return true;
end

local function render_profession_range_details()
    local pdata=profession_data[selected_profession];
    if not pdata then return; end
    local r=pdata.ranges and pdata.ranges[selected_profession_range];
    if not r then return; end
    local structured=skill_range_data[selected_profession] and skill_range_data[selected_profession][selected_profession_range] or nil;

    heading('PROFESSION / ' .. selected_profession:upper());
    title_text(selected_profession .. ' — Skill ' .. selected_profession_range);
    wrapped((r.rank or '') .. ' skill bracket.');
    if imgui.Button('Open this skill range on wiki') then ashita.misc.open_url(r.url); end
    imgui.SameLine();
    if imgui.SmallButton(selected_profession=='Fishing' and 'All Fish' or ('All ' .. selected_profession .. ' Recipes')) then ashita.misc.open_url(pdata.recipes_url); end
    imgui.Separator();

    if not render_skill_range_entries(selected_profession,selected_profession_range,structured) then
        if not render_inline_range_blocks(r.blocks or {}) then
            heading('SKILL RANGE');
            wrapped('No in-addon list has been imported for this bracket yet. The wiki button above is still available if you want the raw source page.');
        end
    end

    if pdata.primary_guide_id~='' and catalog_index[pdata.primary_guide_id] then
        imgui.Spacing();
        heading('GUIDE');
        wrapped('Want a recommended path instead of the full skill-range list? Open the profession guide separately.');
        if imgui.SmallButton('Open ' .. (pdata.primary_guide_title~='' and pdata.primary_guide_title or 'profession guide')) then
            selected=catalog_index[pdata.primary_guide_id]; details_selection=nil;
        end
    end
end

-- Getting Started mode turns the left browser into a focused nation hub.
-- It keeps the full catalog available through "Browse all", but avoids showing
-- hundreds of unrelated entries to a new player who has picked a starting nation.
local function normalize_nation(value)
    return (value or ''):lower():gsub('[^%a]', '');
end

local function starter_path_id(nation)
    local key=normalize_nation(nation);
    if key=='sandoria' then return 'starter_sandoria'; end
    if key=='windurst' then return 'starter_windurst'; end
    if key=='bastok' then return 'starter_bastok'; end
    return nil;
end

local function starter_path_for(nation)
    local id=starter_path_id(nation);
    local i=id and catalog_index[id] or nil;
    return i and catalog[i] or nil, i;
end

local function starter_recommended_ids(nation)
    local set={};
    local path=starter_path_for(nation);
    if path then
        for _,s in ipairs(path.steps or {}) do
            if s.link_id then set[s.link_id]=true; end
        end
    end
    return set;
end

local function nation_entries(nation,kind)
    local out={};
    local target=normalize_nation(nation);
    local recommended=starter_recommended_ids(nation);
    for i,q in ipairs(catalog) do
        if q.kind==kind and normalize_nation(q.group)==target then out[#out+1]=i; end
    end
    table.sort(out,function(a,b)
        local qa,qb=catalog[a],catalog[b];
        local ra,rb=recommended[qa.id] and 1 or 0,recommended[qb.id] and 1 or 0;
        if kind=='quest' and ra~=rb then return ra>rb; end
        if kind=='mission' then
            local a1,a2=(qa.title or ''):match('Mission%s+(%d+)%-(%d+)');
            local b1,b2=(qb.title or ''):match('Mission%s+(%d+)%-(%d+)');
            local an=(tonumber(a1) or 99)*10+(tonumber(a2) or 9);
            local bn=(tonumber(b1) or 99)*10+(tonumber(b2) or 9);
            if an~=bn then return an<bn; end
        end
        return (qa.title or ''):lower() < (qb.title or ''):lower();
    end);
    return out,recommended;
end

local function contains_any(text,terms)
    text=(text or ''):lower();
    for _,term in ipairs(terms) do if text:find(term,1,true) then return true; end end
    return false;
end

local function guide_applies_to_nation(q,nation)
    local title=(q.title or ''):lower();
    local target=normalize_nation(nation);
    if contains_any(title,{"san d'oria",'san doria','sandoria'}) then return target=='sandoria'; end
    if title:find('windurst',1,true) then return target=='windurst'; end
    if title:find('bastok',1,true) then return target=='bastok'; end
    return true;
end

local function guide_category(q)
    local title=(q.title or ''):lower();
    if #(q.jobs or {})>0 or contains_any(title,{
        'black mage','white mage','red mage','blue mage','summoner','ninja','beastmaster','bst ',
        'puppetmaster','paladin','warrior','monk','thief','dragoon','dark knight','ranger','bard',
        'corsair','equipment guide','solo guide','macro guide','healing','parry','sata','manaburn'
    }) then return 'jobs'; end
    if contains_any(title,{
        'alchemy','cooking','smithing','fishing','clamming','craft','woodworking','goldsmith',
        'clothcraft','leathercraft','bonecraft','harvest','mining','logging','chocobo digging'
    }) then return 'professions'; end
    if contains_any(title,{
        'getting started','beginner','new player','progression','exp camp','xp part','party',
        'level guide','new player faq','reputation','map guide'
    }) then return 'progression'; end
    if contains_any(title,{
        'gil','auction house','economy','treasure','coffer','chest','notorious monster','drops',
        'weeklies','festival'
    }) then return 'activities'; end
    return 'reference';
end

local function starter_guides(nation)
    local groups={progression={},jobs={},professions={},activities={},reference={}};
    local path,path_index=starter_path_for(nation);
    if path_index then groups.progression[#groups.progression+1]=path_index; end
    for i,q in ipairs(catalog) do
        if q.kind=='guide' and guide_applies_to_nation(q,nation) then
            local bucket=guide_category(q);
            groups[bucket][#groups[bucket]+1]=i;
        end
    end
    for _,items in pairs(groups) do
        table.sort(items,function(a,b) return (catalog[a].title or ''):lower() < (catalog[b].title or ''):lower(); end);
    end
    return groups;
end

local function starter_selectable(i,p,recommended,prefix)
    local q=catalog[i];
    if not q then return; end
    local lead='';
    if recommended and recommended[q.id] then lead='[Starter] '; end
    if p and p.completed[q.id] then lead='[Done] ' .. lead; end
    if imgui.Selectable(lead .. q.title .. '##' .. (prefix or 'starter') .. '_' .. q.id,selected==i) then
        selected=i; details_selection=nil;
    end
end

local function starter_subsection(label,items,p,recommended,key)
    if imgui.CollapsingHeader(label .. ' (' .. #items .. ')##' .. key) then
        imgui.Indent(8);
        for _,i in ipairs(items) do starter_selectable(i,p,recommended,key); end
        imgui.Unindent(8);
    end
end

local function render_starter_sidebar(p)
    local nation=p.start_nation or '';
    heading('GETTING STARTED');
    local nation_font=push_font(bold_font,15.0);
    imgui.TextWrapped(nation);
    pop_font(nation_font);
    wrapped('A focused view for your starting nation. Expand only the section you need.');
    if imgui.SmallButton('Change nation') then imgui.OpenPopup('starter_nation_change'); end
    if imgui.BeginPopup('starter_nation_change') then
        heading('CHOOSE YOUR STARTING NATION');
        for _,choice in ipairs({{'San d\'Oria','starter_sandoria'},{'Windurst','starter_windurst'},{'Bastok','starter_bastok'}}) do
            if imgui.Selectable(choice[1] .. '##starter_change',p.start_nation==choice[1]) then
                p.start_nation=choice[1]; p.starter_mode=true; hub_mode='starter'; save();
                open_entry(choice[2]); details_selection=nil; imgui.CloseCurrentPopup();
            end
        end
        imgui.EndPopup();
    end
    imgui.SameLine();
    if imgui.SmallButton('Browse all') then
        p.starter_mode=false; hub_mode='all'; query[1]=''; filter='all'; follow_zone[1]=false; zone_choice='All zones'; save();
    end
    imgui.Separator();

    local path,path_index=starter_path_for(nation);
    if path then
        heading('NEXT RECOMMENDED');
        local n=step_index(path,p);
        if n<=#path.steps then
            imgui.TextColored({0.60,0.73,0.79,1},'Starter step ' .. n .. ' / ' .. #path.steps);
            local s=path.steps[n];
            local objective=(s.text or ''):match('([^\n]+)') or (s.text or '');
            if #objective>150 then objective=objective:sub(1,150) .. '...'; end
            wrapped(objective);
            if s.link_id and s.link_title and s.link_title~='' then
                imgui.TextDisabled(s.link_title);
                if accent_button('Open next step##next_starter') then open_entry(s.link_id); cache_key=nil; end
            elseif path_index and imgui.Button('Open starter checklist##next_starter') then
                selected=path_index; details_selection=nil;
            end
        else
            wrapped('Your starter checklist is complete. Use the sections below for your next goal.');
        end
        if path_index and imgui.SmallButton('Full starter checklist') then selected=path_index; details_selection=nil; end
        imgui.Separator();
    end

    local missions,recommended=nation_entries(nation,'mission');
    local quests=nation_entries(nation,'quest');
    if imgui.CollapsingHeader('MISSIONS (' .. #missions .. ')##starter_missions') then
        imgui.Indent(8);
        for _,i in ipairs(missions) do starter_selectable(i,p,recommended,'starter_mission'); end
        imgui.Unindent(8);
    end
    if imgui.CollapsingHeader('QUESTS (' .. #quests .. ')##starter_quests') then
        imgui.Indent(8);
        for _,i in ipairs(quests) do starter_selectable(i,p,recommended,'starter_quest'); end
        imgui.Unindent(8);
    end
    if imgui.CollapsingHeader('GUIDES##starter_guides') then
        local guides=starter_guides(nation);
        imgui.Indent(8);
        starter_subsection('New player & progression',guides.progression,p,recommended,'starter_progression');
        starter_subsection('Jobs & combat',guides.jobs,p,recommended,'starter_jobs');
        starter_subsection('Crafting & professions',guides.professions,p,recommended,'starter_professions');
        starter_subsection('Gil, economy & activities',guides.activities,p,recommended,'starter_activities');
        starter_subsection('Other reference',guides.reference,p,recommended,'starter_reference');
        imgui.Unindent(8);
    end
end

ashita.events.register('command', 'horizonguide_command', function(e)
    local c = e.command:lower():match('^%s*(.-)%s*$');
    local command, argument = c:match('^(/%S+)%s*(.-)$');
    if command ~= '/hg' and command ~= '/horizonguide' and command ~= '/hguide' then return; end
    e.blocked=true;
    if argument == 'hide' or argument == 'close' then
        visible[1]=false; tracker[1]=false;
    elseif argument == 'tracker' then
        tracker[1]=not tracker[1];
    elseif argument == '' or argument == 'show' then
        visible[1]=true;
    end
end);
local function render_top_toolbar(p)
    if imgui.SmallButton('Getting started') then imgui.OpenPopup('starter_nation'); end
    if imgui.BeginPopup('starter_nation') then
        heading('CHOOSE YOUR STARTING NATION');
        wrapped('Saved per character. This does not change your in-game nation.');
        for _,choice in ipairs({{'San d\'Oria','starter_sandoria'},{'Windurst','starter_windurst'},{'Bastok','starter_bastok'}}) do
            if imgui.Selectable(choice[1] .. '##starter',p and p.start_nation==choice[1] or false) then
                if p then p.start_nation=choice[1]; p.starter_mode=true; save(); end
                hub_mode='starter'; open_entry(choice[2]); cache_key=nil; imgui.CloseCurrentPopup();
            end
        end
        imgui.EndPopup();
    end
    imgui.SameLine();
    if imgui.SmallButton('Jobs') then if p then p.starter_mode=false; save(); end; hub_mode='jobs'; selected=nil; details_selection=nil; end
    imgui.SameLine();
    if imgui.SmallButton('Professions') then if p then p.starter_mode=false; save(); end; hub_mode='professions'; selected=nil; details_selection=nil; end
    imgui.SameLine();
    if imgui.SmallButton('Guides') then if p then p.starter_mode=false; save(); end; hub_mode='all'; filter='guide'; query[1]=''; follow_zone[1]=false; zone_choice='All zones'; cache_key=nil; end
    imgui.SameLine();
    if imgui.SmallButton('Window size') then imgui.OpenPopup('window_size'); end
    if imgui.BeginPopup('window_size') then
        if imgui.Selectable('Compact - 800 x 560',false) then pending_size={800,560}; show_panel[1]=false; end
        if imgui.Selectable('Standard - 1000 x 680',false) then pending_size={1000,680}; end
        if imgui.Selectable('Large - 1200 x 800',false) then pending_size={1200,800}; end
        imgui.EndPopup();
    end
    imgui.Checkbox('Side tracker',show_panel);
    imgui.SameLine();
    if imgui.SmallButton('Close all menus') then visible[1]=false; tracker[1]=false; end
    imgui.SameLine(); imgui.TextDisabled('/hg to reopen');
    imgui.Separator();
end

local function render_browser_sidebar(p, character)
    local focused_sidebar=(p and p.starter_mode and p.start_nation~='') or hub_mode=='jobs' or hub_mode=='professions';
    if begin_child('sidebar', { focused_sidebar and 300 or 235, 0 }) then
    if p and p.starter_mode and p.start_nation~='' then
        render_starter_sidebar(p);
    elseif hub_mode=='jobs' then
        render_jobs_sidebar(p);
    elseif hub_mode=='professions' then
        render_profession_sidebar(p);
    else
    wrapped('Search quests');
    imgui.SetNextItemWidth(-1);
    imgui.InputText('##guide_search', query, 256);
    if imgui.SmallButton('Filters / Zone') then imgui.OpenPopup('guide_filters'); end
    imgui.SetNextWindowSize({ 380, 0 }, ImGuiCond_Always);
    if imgui.BeginPopup('guide_filters') then
    heading('QUEST FILTERS');
    if imgui.Button('All') then filter='all'; end
    imgui.SameLine(); if imgui.Button('Quests') then filter='quest'; end
    imgui.SameLine(); if imgui.Button('Missions') then filter='mission'; end
    if imgui.Button('Job quests') then filter='job'; end
    if filter == 'job' then
        if imgui.BeginCombo('Job', job_choice, 0) then
            if imgui.Selectable('All jobs', job_choice == 'All jobs') then job_choice='All jobs'; end
            for _,job in ipairs(job_names) do
                if imgui.Selectable(job, job_choice == job) then job_choice=job; end
            end
            imgui.EndCombo();
        end
    end
    imgui.Checkbox('Show manually completed',show_completed);
    imgui.Checkbox('Show planned / unavailable',show_planned);
    imgui.Separator();
    heading('ZONE FILTER');
    local detected_zone=current_zone(p);
    imgui.Checkbox('Follow my current zone',follow_zone);
    if follow_zone[1] then
        wrapped('Current: ' .. (detected_zone or 'Unknown / zoning'));
    else
        imgui.SetNextItemWidth(-1);
        if imgui.BeginCombo('##zone_choice',zone_choice,0) then
            imgui.InputText('Find zone',zone_search,128);
            if imgui.Selectable('All zones##zone',zone_choice=='All zones') then zone_choice='All zones'; end
            for _,zone in ipairs(zone_names) do
                if zone:lower():find(zone_search[1]:lower(),1,true) then
                    if imgui.Selectable(zone .. '##zone',zone_choice==zone) then zone_choice=zone; end
                end
            end
            imgui.EndCombo();
        end
    end
    imgui.SetNextItemWidth(-1);
    if imgui.BeginCombo('##zone_mode',zone_mode,0) then
        if imgui.Selectable('Starts here##zone_mode',zone_mode=='Starts here') then zone_mode='Starts here'; end
        if imgui.Selectable('Has steps here##zone_mode',zone_mode=='Has steps here') then zone_mode='Has steps here'; end
        imgui.EndCombo();
    end
    if follow_zone[1] or zone_choice~='All zones' then
        wrapped('Wiki locations only. Check requirements.');
        if zone_mode=='Has steps here' then wrapped('Includes zone mentions in notes.'); end
    end
    if imgui.SmallButton('Clear zone filter') then
        follow_zone[1]=false; zone_choice='All zones';
    end
    if imgui.Button('Done##filters') then imgui.CloseCurrentPopup(); end
    imgui.EndPopup();
    end
    local active_zone=zone_choice;
    if follow_zone[1] then active_zone=current_zone(p); end
    if filter~='all' then wrapped(filter=='job' and ('Job: ' .. job_choice) or filter); end
    if active_zone~='All zones' then
        wrapped((follow_zone[1] and 'Here: ' or 'Zone: ') .. (active_zone or 'Unknown / zoning'));
        imgui.TextDisabled(zone_mode);
    end
    refresh(p,character,active_zone);
    imgui.Text(tostring(#filtered) .. ' guides');
    if begin_child('quest_list', { 0, 0 }) then
        for _,i in ipairs(filtered) do
            local q=catalog[i];
            local label=(p and p.completed[q.id] and '[Done] ' or '') .. q.title;
            imgui.TextColored({0.60,0.73,0.79,1}, q.kind:upper());
            if imgui.Selectable(label .. '##' .. q.id, selected == i) then selected=i; end
            imgui.Separator();
        end
    end
    imgui.EndChild();
    end
    end
    imgui.EndChild(); imgui.SameLine();
end

local function render_details_panel(p)
    if begin_child('details', { show_panel[1] and -250 or 0, 0 }) then
        local detail_key=selected;
        if not selected and hub_mode=='professions' then detail_key='profession:' .. selected_profession .. ':' .. selected_profession_range; end
        if not selected and hub_mode=='jobs' then detail_key='job:' .. selected_job_hub; end
        if details_selection~=detail_key then imgui.SetScrollY(0); details_selection=detail_key; end
        local q=selected and catalog[selected];
        if not q and hub_mode=='professions' then
            render_profession_range_details();
        elseif not q and hub_mode=='jobs' then
            heading('JOBS');
            if selected_job_hub=='' then title_text('Choose a job'); wrapped('Pick a job from the left to see its related quests and guides.');
            else title_text(selected_job_hub); wrapped('Choose a quest or guide from the left. Job-related quest lists are based on the HorizonXI Wiki metadata imported into HorizonGuide.'); end
        elseif q then
            heading(q.kind:upper() .. ' / ' .. q.group:upper());
            title_text(q.title);
            if imgui.Button('Open wiki in browser') then ashita.misc.open_url(q.source); end
            imgui.SameLine();
            if imgui.SmallButton('Copy wiki link') then imgui.SetClipboardText(q.source); end
            imgui.Separator();
            wrapped(q.kind .. ' | ' .. q.group .. ' | Server availability: ' .. q.availability);
            wrapped(q.warnings); wrapped(q.summary);
            if #(q.start_zones or {}) > 0 then wrapped('Starts in: ' .. table.concat(q.start_zones, ', ')); end
            if #(q.jobs or {}) > 0 then wrapped('Job: ' .. table.concat(q.jobs, ', ')); end
            imgui.Separator();
            if is_reference_guide(q) then
                -- Reference pages (crafting lists, NM tables, FAQs, gear guides,
                -- dictionaries, etc.) are informational. Do not show fake progress,
                -- Start here buttons, rewards, or Step done controls for them.
                if q.changes ~= '' then
                    heading('HORIZON CHANGES'); wrapped(q.changes); imgui.Spacing();
                end
                render_reference_guide(q);
            else
                imgui.PushStyleColor(ImGuiCol_Border, {0.20,0.31,0.35,1});
                if begin_child('overview_card##' .. q.id, {0, 165}) then
                    heading('BEFORE YOU BEGIN'); wrapped(q.requirements);
                    imgui.Spacing(); heading('REWARDS'); wrapped(q.rewards);
                    if q.kind=='quest' or q.kind=='mission' then wrapped('Repeatable: ' .. q.repeatable); end
                end
                imgui.EndChild();
                imgui.PopStyleColor();
                if q.changes ~= '' then
                    imgui.Spacing();
                    heading('HORIZON CHANGES'); wrapped(q.changes);
                end
                imgui.Spacing();
                if p then
                    if accent_button('Track guide') then p.tracked=q.id; tracker[1]=true; save(); end
                    imgui.SameLine();
                    if p.completed[q.id] then
                        if imgui.Button('Clear manual completion') then p.completed[q.id]=nil; save(); end
                    else
                        if imgui.Button(q.kind=='path' and 'Mark guide finished (manual)' or 'Mark quest complete (manual)') then
                            p.completed[q.id]=true;
                            if p.tracked==q.id then p.tracked=''; end
                            save();
                        end
                    end
                end
                imgui.Separator();
                heading('GUIDE BLOCKS');
                wrapped('Walkthrough actions from the wiki. Section headings, fight notes, and testimony are separated from manual progress.');
                local n=step_index(q,p);
                if #q.steps == 0 then
                    wrapped('No imported guide blocks are available for this entry.');
                elseif show_all_blocks[1] then
                    if imgui.SmallButton('Show current block only##blocks') then show_all_blocks[1]=false; end
                    imgui.Spacing();
                    for j,s in ipairs(q.steps) do
                        if not is_non_actionable_index(q,j) then
                            render_step_card(q,p,j,s);
                            imgui.Spacing();
                        end
                    end
                else
                    if imgui.SmallButton('Show all blocks##blocks') then show_all_blocks[1]=true; end
                    imgui.Spacing();
                    local shown;
                    if n>#q.steps then shown=previous_actionable_index(q,#q.steps+1);
                    else shown=next_actionable_index(q,n); end
                    if shown<=#q.steps and not is_non_actionable_index(q,shown) then
                        render_step_card(q,p,shown,q.steps[shown]);
                    else
                        wrapped('No actionable walkthrough blocks are available for this entry.');
                    end
                end
                imgui.Spacing();
                controls(q,p);
                local notes=supplemental_steps(q);
                if #notes > 0 then
                    imgui.Spacing();
                    heading('ADDITIONAL NOTES / TESTIMONY');
                    wrapped('Useful wiki fight notes, strategy details, and player testimony are kept here for reference. They are not counted as required walkthrough steps.');
                    imgui.Spacing();
                    imgui.PushStyleColor(ImGuiCol_Border, {0.20,0.31,0.35,1});
                    if begin_child('supplemental_card##' .. q.id, {0, math.min(96 + (#notes * 72), 320)}) then
                        local last_section='';
                        for idx,item in ipairs(notes) do
                            local section=trim_text(item.section);
                            if section~='' and section~=last_section then
                                if last_section~='' then imgui.Separator(); end
                                imgui.TextColored(gold, section:upper());
                                imgui.Spacing();
                                last_section=section;
                            end
                            wrapped(item.step.text);
                            if idx < #notes then imgui.Spacing(); end
                        end
                    end
                    imgui.EndChild();
                    imgui.PopStyleColor();
                end
                if q.kind=='path' then wrapped('Each linked quest or guide includes its own wiki source.'); end
            end
            imgui.Spacing();
            wrapped('Source: ' .. q.source); wrapped('Wiki revision: ' .. q.revision);
        else wrapped('No matching guides. Try clearing the search or changing filters.'); end
    end
    imgui.EndChild();
end

local function render_side_tracker_panel(p, character)
    if show_panel[1] then
    imgui.SameLine();
    if begin_child('tracking_panel', {0,0}) then
        heading('MANUAL TRACKER');
        local tracked;
        if p then
            for _,candidate in ipairs(catalog) do if candidate.id==p.tracked then tracked=candidate; break; end end
        end
        if tracked then
            wrapped(tracked.title);
            if is_reference_guide(tracked) then
                wrapped('Reference pages do not use step tracking.');
                if imgui.Button('Stop tracking##panel') then p.tracked=''; save(); end
            else
                local n=step_index(tracked,p);
                local total=actionable_step_count(tracked);
                local shown_number=n<=#tracked.steps and actionable_step_number(tracked,n) or total;
                imgui.Text('Step ' .. shown_number .. ' / ' .. total);
                if begin_child('panel_objective', {0,220}) then
                    if n<=#tracked.steps then
                        local section=section_heading_before(tracked,n);
                        if section~='' then imgui.TextColored({0.66,0.80,0.84,1}, section); imgui.Spacing(); end
                        for _,note in ipairs(structural_notes_before(tracked,n)) do
                            imgui.TextColored({0.92,0.76,0.42,1}, 'NOTE');
                            wrapped(note:gsub('^[Nn][Oo][Tt][Ee]%s*:%s*',''):gsub('^[Ww][Aa][Rr][Nn][Ii][Nn][Gg]%s*:%s*',''));
                        end
                        show_step(tracked.steps[n]);
                    else wrapped('Guide steps finished. Quest completion is still manual.'); end
                end
                imgui.EndChild();
                if n<=#tracked.steps and imgui.Button('Step done##panel') then mark_started(tracked,p); p.progress[tracked.id]=next_actionable_index(tracked,n+1); save(); end
                if imgui.Button('Previous##panel') then p.progress[tracked.id]=previous_actionable_index(tracked,n); save(); end
                if imgui.Button('Stop tracking##panel') then p.tracked=''; save(); end
                imgui.Checkbox('Floating tracker',tracker);
            end
        else wrapped('Choose a quest or mission and select Track guide.'); end
        imgui.Separator();
        wrapped('Character: ' .. character);
        wrapped('Completion is not synced with the game.');
    end
    imgui.EndChild();
    end
end

local function render_floating_tracker(p)
    if tracker[1] and p and p.tracked ~= '' then
    local q, tracked_index;
    for i,candidate in ipairs(catalog) do
    if candidate.id==p.tracked then q=candidate; tracked_index=i; break; end
    end
    if q and not is_reference_guide(q) then
    local tracker_font_pushed = push_font(body_font, 15.0);
    imgui.SetNextWindowSize({ 390, 0 }, ImGuiCond_Always);
    -- The old tracker deliberately used NoBackground, which made text disappear
    -- into bright game scenes. Give it an almost-opaque dark card instead.
    imgui.PushStyleColor(ImGuiCol_WindowBg, {0.035,0.060,0.072,0.94});
    imgui.PushStyleColor(ImGuiCol_Border, {0.34,0.42,0.44,0.96});
    imgui.PushStyleColor(ImGuiCol_Text, {0.94,0.96,0.97,1.0});
    imgui.PushStyleColor(ImGuiCol_Button, {0.12,0.20,0.23,0.96});
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.20,0.31,0.35,1.0});
    imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.30,0.37,0.30,1.0});
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {10,8});
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 3);
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoMove, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoScrollbar);
    if imgui.Begin('HorizonGuide floating tracker###HorizonGuideFloatingTracker',tracker,flags) then
        local n=step_index(q,p);
        imgui.PushStyleColor(ImGuiCol_Button, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 1, 1, 1, 0.10 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 1, 1, 1, 0.15 });
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.82, 0.25, 1.0 });
        if imgui.ArrowButton('##tracker_expand', p.tracker_collapsed and ImGuiDir_Right or ImGuiDir_Down) then
            p.tracker_collapsed=not p.tracker_collapsed; save();
        end
        imgui.SameLine();
        local open = imgui.Button(q.title .. '##open_tracked');
        if imgui.IsItemActive() and imgui.IsMouseDragging(0, title_dragged and 0 or 5) then
            local x,y=imgui.GetWindowPos();
            local dx,dy=imgui.GetMouseDragDelta(0, 0);
            imgui.SetWindowPos({ x+dx, y+dy }, ImGuiCond_Always);
            imgui.ResetMouseDragDelta(0);
            title_dragged=true;
        end
        if imgui.IsMouseReleased(0) then
            if title_dragged then open=false; end
            title_dragged=false;
        end
        imgui.PopStyleColor(4);
        if open then
            visible[1]=true; query[1]=''; filter='all'; selected=tracked_index;
            follow_zone[1]=false; zone_choice='All zones';
            if q.availability=='unavailable' then show_planned[1]=true; end
            if p.completed[q.id] then show_completed[1]=true; end
            cache_key=nil;
        end
        if not p.tracker_collapsed then
        if n<=#q.steps then
            if q.steps[n].zone~='' then wrapped(q.steps[n].zone); end
            local total=actionable_step_count(q);
            imgui.Text('Step ' .. actionable_step_number(q,n) .. ' / ' .. total .. ' (manual)');
            local section=section_heading_before(q,n);
            if section~='' then imgui.TextColored({0.66,0.80,0.84,1}, section); end
            local objective=q.steps[n].text:match('([^\n]+)') or q.steps[n].text;
            if #objective>220 then objective=objective:sub(1,220) .. '...'; end
            wrapped(objective);
            if q.steps[n].link_id and imgui.SmallButton('Open instructions##tracker') then open_entry(q.steps[n].link_id); cache_key=nil; end
            if q.steps[n].grid~='' then wrapped('Map: ' .. q.steps[n].grid); end
            if imgui.SmallButton('Step done##tracker') then mark_started(q,p); p.progress[q.id]=next_actionable_index(q,n+1); save(); end
            imgui.SameLine();
        else
            wrapped('Guide steps finished. Confirm quest completion in the full guide.');
        end
        if imgui.SmallButton('Back##tracker') then p.progress[q.id]=previous_actionable_index(q,n); save(); end
        imgui.SameLine();
        if imgui.SmallButton('Untrack') then p.tracked=''; save(); end
        end
    end
    imgui.End();
    imgui.PopStyleVar(4);
    imgui.PopStyleColor(6);
    pop_font(tracker_font_pushed);
    end
    end
end

local function render_main_window(p, character)
    if not visible[1] then return; end
    push_theme();
    local main_font_pushed = push_font(body_font, 15.0);
    if pending_size then
        imgui.SetNextWindowSize(pending_size, ImGuiCond_Always); pending_size=nil;
    else
        imgui.SetNextWindowSize({ 1000, 680 }, ImGuiCond_FirstUseEver);
    end
    imgui.SetNextWindowSizeConstraints({ 760, 460 }, { 10000, 10000 });
    if imgui.Begin('HorizonGuide 0.4.1 - Wiki browser', visible) then
        render_top_toolbar(p);
        render_browser_sidebar(p, character);
        render_details_panel(p);
        render_side_tracker_panel(p, character);
    end
    imgui.End();
    pop_font(main_font_pushed);
    imgui.PopStyleVar(5);
    imgui.PopStyleColor(14);
end

ashita.events.register('d3d_present', 'horizonguide_present', function()
    local p, character = profile();
    render_main_window(p, character);
    render_floating_tracker(p);
end);
ashita.events.register('unload', 'horizonguide_unload', save);
