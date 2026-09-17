addon.name = 'horizonguide';
addon.author = 'valzar';
addon.version = '0.2.5';
addon.desc = 'Offline Horizon wiki browser with manual guide tracking.';
require('common');
local imgui = require('imgui');
local bit = require('bit');
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
local selected = nil;
local title_dragged = false;
local filtered, cache_key = {}, nil;
local searchable = {};
for i,q in ipairs(catalog) do
    local terms = q.title .. ' ' .. q.requirements .. ' ' .. q.group .. ' ' .. table.concat(q.jobs or {}, ' ');
    for _,s in ipairs(q.steps) do terms = terms .. ' ' .. s.zone .. ' ' .. s.npc; end
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
    if not state.profiles[key] then state.profiles[key] = { progress = {}, completed = {}, tracked = '' }; end
    return state.profiles[key], n;
end
local function step_index(q,p)
    return math.max(1, math.min(#q.steps + 1, tonumber(p and p.progress[q.id]) or 1));
end
local function wrapped(s) if s and s ~= '' then imgui.TextWrapped(s); end end
local gold = { 0.95, 0.78, 0.43, 1 };
local function heading(text)
    imgui.TextColored(gold, text);
    imgui.Spacing();
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
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {16,16});
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {9,7});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {8,10});
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
end
local function show_step(s)
    wrapped(s.text);
    if s.zone ~= '' then wrapped('Zone: ' .. s.zone); end
    if s.grid ~= '' then wrapped('Map square: ' .. s.grid); end
end
local function controls(q,p)
    if not p then wrapped('Log in to save manual progress.'); return; end
    local n = step_index(q,p);
    if n <= #q.steps then
        if imgui.Button('Step done##' .. q.id) then p.progress[q.id] = n + 1; save(); end
    else
        wrapped('Guide steps finished. Quest completion has not been verified.');
    end
    if imgui.Button('Previous step##' .. q.id) then p.progress[q.id] = math.max(1,n - 1); save(); end
end
local function refresh(p, char)
    local key = query[1] .. ':' .. filter .. ':' .. tostring(show_completed[1]) .. ':' .. tostring(show_planned[1]) .. ':' .. char .. ':' .. job_choice;
    if key == cache_key then return; end
    cache_key = key; filtered = {};
    for i,q in ipairs(catalog) do
        local complete = p and p.completed[q.id];
        if (show_completed[1] or not complete) and (show_planned[1] or q.availability ~= 'unavailable')
            and (filter == 'all' or q.kind == filter or (filter == 'job' and matches_job(q))) and searchable[i]:find(query[1]:lower(),1,true) then
            filtered[#filtered + 1] = i;
        end
    end
    local found = false;
    for _,i in ipairs(filtered) do if i == selected then found = true; break; end end
    if not found then selected = filtered[1]; end
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
ashita.events.register('d3d_present', 'horizonguide_present', function()
    local p, character = profile();
    if visible[1] then
        push_theme();
        imgui.SetNextWindowSize({ 1120, 720 }, ImGuiCond_FirstUseEver);
        imgui.SetNextWindowSizeConstraints({ 920, 480 }, { 10000, 10000 });
        if imgui.Begin('HorizonGuide 0.2.5 - Wiki browser', visible) then
            if begin_child('sidebar', { 235, 0 }) then
            heading('HORIZONGUIDE');
            wrapped('Created by valzar');
            if imgui.SmallButton('Close all menus') then visible[1]=false; tracker[1]=false; end
            wrapped('/hg to reopen');
            wrapped('Search title, NPC or location');
            imgui.SetNextItemWidth(-1);
            imgui.InputText('##guide_search', query, 256);
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
            refresh(p,character);
            imgui.Text(tostring(#filtered) .. ' guides shown / ' .. tostring(#catalog) .. ' imported');
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
            imgui.EndChild(); imgui.SameLine();
            if begin_child('details', { -250, 0 }) then
                local q=selected and catalog[selected];
                if q then
                    heading(q.kind:upper() .. ' / ' .. q.group:upper());
                    wrapped(q.title);
                    if imgui.Button('Open wiki in browser') then ashita.misc.open_url(q.source); end
                    imgui.SameLine();
                    if imgui.SmallButton('Copy wiki link') then imgui.SetClipboardText(q.source); end
                    imgui.Separator();
                    wrapped(q.kind .. ' | ' .. q.group .. ' | Server availability: ' .. q.availability);
                    wrapped(q.warnings); wrapped(q.summary);
                    if #(q.jobs or {}) > 0 then wrapped('Job: ' .. table.concat(q.jobs, ', ')); end
                    if begin_child('before_you_begin', {0, 205}) then
                        heading('BEFORE YOU BEGIN'); wrapped(q.requirements);
                        imgui.Spacing(); heading('REWARDS'); wrapped(q.rewards);
                        wrapped('Repeatable: ' .. q.repeatable);
                    end
                    imgui.EndChild();
                    if q.changes ~= '' then wrapped('HORIZON CHANGES'); wrapped(q.changes); end
                    if p then
                        imgui.PushStyleColor(ImGuiCol_Button, gold);
                        imgui.PushStyleColor(ImGuiCol_Text, {0.055,0.09,0.105,1});
                        if imgui.Button('Track guide') then p.tracked=q.id; tracker[1]=true; save(); end
                        imgui.PopStyleColor(2);
                        if p.completed[q.id] then
                            if imgui.Button('Clear manual completion') then p.completed[q.id]=nil; save(); end
                        else
                            if imgui.Button('Mark quest complete (manual)') then
                                p.completed[q.id]=true;
                                if p.tracked==q.id then p.tracked=''; end
                                save();
                            end
                        end
                    end
                    imgui.Separator();
                    heading('GUIDE STEPS');
                    wrapped('Check off steps manually as you follow the guide.');
                    local n=step_index(q,p);
                    for j,s in ipairs(q.steps) do
                        heading((j<n and 'DONE - ' or j==n and 'CURRENT - ' or 'STEP ') .. j .. ' / ' .. #q.steps);
                        show_step(s);
                        if p and imgui.SmallButton('Start here##' .. q.id .. '_' .. j) then p.progress[q.id]=j; save(); end
                        imgui.Separator();
                    end
                    controls(q,p);
                    wrapped('Source: ' .. q.source); wrapped('Wiki revision: ' .. q.revision);
                else wrapped('No matching guides. Try clearing the search or changing filters.'); end
            end
            imgui.EndChild(); imgui.SameLine();
            if begin_child('tracking_panel', {0,0}) then
                heading('MANUAL TRACKER');
                local tracked;
                if p then
                    for _,candidate in ipairs(catalog) do if candidate.id==p.tracked then tracked=candidate; break; end end
                end
                if tracked then
                    wrapped(tracked.title);
                    local n=step_index(tracked,p);
                    imgui.Text('Step ' .. math.min(n,#tracked.steps) .. ' / ' .. #tracked.steps);
                    if begin_child('panel_objective', {0,220}) then
                        if n<=#tracked.steps then show_step(tracked.steps[n]);
                        else wrapped('Guide steps finished. Quest completion is still manual.'); end
                    end
                    imgui.EndChild();
                    if n<=#tracked.steps and imgui.Button('Step done##panel') then p.progress[tracked.id]=n+1; save(); end
                    if imgui.Button('Previous##panel') then p.progress[tracked.id]=math.max(1,n-1); save(); end
                    if imgui.Button('Stop tracking##panel') then p.tracked=''; save(); end
                    imgui.Checkbox('Floating tracker',tracker);
                else wrapped('Choose a quest and select Track guide.'); end
                imgui.Separator();
                wrapped('Character: ' .. character);
                wrapped('Completion is not synced with the game.');
            end
            imgui.EndChild();
        end
        imgui.End();
        imgui.PopStyleVar(5);
        imgui.PopStyleColor(14);
    end
    if tracker[1] and p and p.tracked ~= '' then
        local q, tracked_index;
        for i,candidate in ipairs(catalog) do
            if candidate.id==p.tracked then q=candidate; tracked_index=i; break; end
        end
        if q then
            imgui.SetNextWindowSize({ 360, 0 }, ImGuiCond_Always);
            local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
                ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoBackground,
                ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoScrollbar);
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
                    if q.availability=='unavailable' then show_planned[1]=true; end
                    if p.completed[q.id] then show_completed[1]=true; end
                    cache_key=nil;
                end
                if not p.tracker_collapsed then
                if n<=#q.steps then
                    if q.steps[n].zone~='' then wrapped(q.steps[n].zone); end
                    imgui.Text('Step ' .. n .. ' / ' .. #q.steps .. ' (manual)');
                    local objective=q.steps[n].text:match('([^\n]+)') or q.steps[n].text;
                    if #objective>220 then objective=objective:sub(1,220) .. '...'; end
                    wrapped(objective);
                    if q.steps[n].grid~='' then wrapped('Map: ' .. q.steps[n].grid); end
                    if imgui.SmallButton('Step done##tracker') then p.progress[q.id]=n+1; save(); end
                    imgui.SameLine();
                else
                    wrapped('Guide steps finished. Confirm quest completion in the full guide.');
                end
                if imgui.SmallButton('Back##tracker') then p.progress[q.id]=math.max(1,n-1); save(); end
                imgui.SameLine();
                if imgui.SmallButton('Untrack') then p.tracked=''; save(); end
                end
            end
            imgui.End();
        end
    end
end);
ashita.events.register('unload', 'horizonguide_unload', save);
