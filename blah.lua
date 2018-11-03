--[[

处理字幕格式的脚本。

大部分的功能需要字幕是"中文\NEnglish"的形式。

可能需要较新版本的Aegisub。

]]

include("karaskel.lua")

-- ============================================================================
-- Util functions, mostly stolen from the Internet
-- ============================================================================
function string:split(sSeparator, nMax, bRegexp)
    assert(sSeparator ~= '')
    assert(nMax == nil or nMax >= 1)

    local aRecord = {}

    if self:len() > 0 then
       local bPlain = not bRegexp
       nMax = nMax or -1

       local nField, nStart = 1, 1

       local nFirst,nLast = self:find(sSeparator, nStart, bPlain)
       while nFirst and nMax ~= 0 do
          aRecord[nField] = self:sub(nStart, nFirst-1)
          nField = nField+1
          nStart = nLast+1
          nFirst,nLast = self:find(sSeparator, nStart, bPlain)
          nMax = nMax-1
       end
       aRecord[nField] = self:sub(nStart)
    end

    return aRecord
end

function string:trim()
    return self:match("^%s*(.-)%s*$")
end

function table.slice(tbl, first, last, step)
    local sliced = {}

    for i = first or 1, last or #tbl, step or 1 do
        sliced[#sliced+1] = tbl[i]
    end

    return sliced
end

function between(a, b, c)
    return a >= b and a <= c
end

function string:get_parts()
    local parts = self:split("\\N", 1)
    local chinese = ""
    local english = ""
    if #parts >= 1 then chinese = parts[1]:trim() end
    if #parts >= 2 then english = parts[2]:trim() end
    return chinese, english, chn_metadata, eng_metadata
end

function combine(chn, eng, chn_metadata, eng_metadata)
    local separator = ""
    if #chn > 0 and #eng > 0 then separator = "\\N" end
    return chn .. separator .. eng
end

function string:startsWith(str)
    return string.sub(self, 1,string.len(str)) == str
end

function string:endsWith(str)
    return str =='' or string.sub(self, -string.len(str)) == str
end

function count_header_lines(subs)
    local num_header_lines = 0
    while num_header_lines <= #subs do
        local line = subs[num_header_lines + 1]
        if line.text == nil then num_header_lines = num_header_lines + 1 else break end
    end
    return num_header_lines
end

--[[ ============================================================================
-- Join (concatenate)
--   合并所有选中的字幕到一行，每行字幕的中文和英文部分会分别合并。
--   合并之后的字幕时间是选中的行的时间总和。
--   如果使用时只选中了一行，则视为选中该行和之前一行。
--
-- Join (use first time)
--   同上，但合并之后的字幕时间取第一行的时间。
--
-- Join (use last time)
--   同上，但合并之后的字幕时间取最后一行的时间。
--]]
function join(subs, sel, mode)
    local first = {}
    local second = {}

    local indices = {}

    if #sel == 1 then
        indices = { sel[1] - 1, sel[1] }
    else
        indices = sel
    end

    local first_start_time = subs[indices[1]].start_time
    local first_end_time = subs[indices[1]].end_time
    local last_start_time = subs[indices[#indices]].start_time
    local last_end_time = subs[indices[#indices]].end_time
    local min_start_time = first_start_time
    local max_end_time = last_end_time

    for _, idx in ipairs(indices) do
        local line = subs[idx]
        local parts = line.text:split("\\N", 1)

        if #parts >= 1 then
            first[#first+1] = parts[1]:trim()
        end
        if #parts >= 2 then
            second[#second+1] = parts[2]:gsub("\\N", " "):trim()
        end

        if line.start_time < min_start_time then
            min_start_time = line.start_time
        end
        if line.end_time > max_end_time then
            max_end_time = line.end_time
        end
    end

    subs.delete(table.slice(indices, 2, #indices))

    local line = subs[indices[1]]
    if (mode == "concatenate") then
        line.start_time = min_start_time
        line.end_time = max_end_time
    elseif (mode == "keep first") then
        line.start_time = first_start_time
        line.end_time = first_end_time
    elseif (mode == "keep last") then
        line.start_time = last_start_time
        line.end_time = last_end_time
    end

    line.text = table.concat(first, "") .. "\\N" .. table.concat(second, " ")
    subs[indices[1]] = line

    return { indices[1] }
end

function join_concatenate(subs, sel)
    return join(subs, sel, "concatenate")
end

function join_keep_first(subs, sel)
    return join(subs, sel, "keep first")
end

function join_keep_last(subs, sel)
    return join(subs, sel, "keep last")
end

function join_validation(subs, sel)
    return #sel > 1 or sel[1] > 1
end

aegisub.register_macro("0.0/Join (concatenate)", "合并双语字幕，合并时间",
    join_concatenate, join_validation)

aegisub.register_macro("0.0/Join (use first time)", "合并双语字幕，取第一行时间",
    join_keep_first, join_validation)

aegisub.register_macro("0.0/Join (use last time)", "合并双语字幕，取最后一行时间",
    join_keep_last, join_validation)

--[[ ============================================================================
-- Split (estimate time)
--   分割选中行，用英文部分的长度估算时间。
--   使用前需在选中的每行字幕中用两个"|"标示分割位置。
--   例如：
--     我是一名艺术家 一名行为艺术家\NI'm an artist. A performance artist.
--   加入分隔符：
--     我是一名艺术家 |一名行为艺术家\NI'm an artist.| A performance artist.
--   分割之后：
--     我是一名艺术家\NI'm an artist.
--     一名行为艺术家\NA performance artist.
--
-- Split (preserve time)
--   同上，但分割之后的两行均使用原字幕的时间。
--
-- Split (current frame)
--   同上，但分割之后的两行的时间会以当前视频时间分割。
--
-- 注：分隔符周围的空格会被删除。
--    如果需要使用其他字符作为分隔符，可以修改代码中的"split_marker"。
--]]
split_marker = "|"

function split_line(subs, sel, mode)
    local delta = 0

    local video_time = aegisub.ms_from_frame(aegisub.project_properties().video_position)

    for _, idx in ipairs(sel) do
        local real_idx = idx + delta
        local line = subs[real_idx]
        local parts = line.text:split("\\N")
        local first = parts[1]:split(split_marker)
        local second = parts[2]:split(split_marker)

        local estimated_split_time = line.start_time + (line.end_time - line.start_time) * (#second[1] / #parts[2])
        local current_end_time = line.end_time

        line.text = first[1]:trim() .. "\\N" .. second[1]:trim()
        if mode == "estimate" then
            line.end_time = estimated_split_time
        elseif mode == "current" then
            line.end_time = video_time
        end
        subs.insert(real_idx, line)

        line.text = first[2]:trim() .. "\\N" .. second[2]:trim()
        if mode == "estimate" then
            line.start_time = estimated_split_time
        elseif mode == "current" then
            line.start_time = video_time
        end
        line.end_time = current_end_time
        subs[real_idx + 1] = line

        delta = delta + 1
    end
end

function split_line_validation(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local parts = line.text:split("\\N")
        if #parts ~= 2 then return false end
        local first = parts[1]:split(split_marker)
        local second = parts[2]:split(split_marker)
        if #first ~= 2 or #second ~= 2 then return false end
    end
    return true
end

aegisub.register_macro("0.0/Split (estimate time)", "分割双语字幕，用英文部分估算时间",
        function (subs, sel) return split_line(subs, sel, "estimate") end, split_line_validation)

aegisub.register_macro("0.0/Split (preserve time)", "分割双语字幕，保留时间",
        function (subs, sel) return split_line(subs, sel, "preserve") end, split_line_validation)

aegisub.register_macro("0.0/Split (current frame)", "分割双语字幕，在当前帧分割时间",
        function (subs, sel) return split_line(subs, sel, "current") end, split_line_validation)

--[[ ============================================================================
-- Toggle capitalization
--   切换英文部分第一个字母的大小写。
--]]
function toggle_capitalization(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local new_text, n = line.text:gsub("\\N(%l)", function (x) return "\\N" .. string.upper(x) end)
        if n == 0 then
            new_text = new_text:gsub("\\N(%u)", function (x) return "\\N" .. string.lower(x) end)
        end
        line.text = new_text
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Toggle capitalization", "切换英文首字母大小写", toggle_capitalization)

--[[ ============================================================================
-- Toggle full stop
--   切换英文部分最后是否加句号。
--
-- Toggle comma
--   切换英文部分最后是否加逗号。
--]]
function toggle_end_char(subs, sel, char)
    local escaped_char
    if char == "." then escaped_char = "%." else escaped_char = char end

    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local new_text, n = line.text:gsub(escaped_char .. "$", "")
        if n == 0 then
            new_text = line.text .. char
        end
        line.text = new_text
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Toggle full stop", "切换英文是否以句号结尾",
    function (subs, sel) return toggle_end_char(subs, sel, ".") end)

aegisub.register_macro("0.0/Toggle comma", "切换英文是否以逗号结尾",
    function (subs, sel) return toggle_end_char(subs, sel, ",") end)

function toggle_begin_char(subs, sel, char)
    local escaped_char
    if char == "." then escaped_char = "%." else escaped_char = char end

    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local new_text, n = line.text:gsub("^" .. escaped_char, "")
        if n == 0 then
            new_text = char .. line.text
        end
        line.text = new_text
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Toggle beginning @", "rt",
    function(subs, sel) return toggle_begin_char(subs, sel, "@") end)

aegisub.register_macro("0.0/Toggle beginning #", "rt",
    function(subs, sel) return toggle_begin_char(subs, sel, "#") end)

--[[ ============================================================================
-- Select current frame
--   选中当前视频时间所对应的字幕。
--   如果当前视频帧中没有字幕，会选中接下来将播放的字幕。
--   如果当前视频帧中有多行字幕，会选中离当前选中字幕最近的一行，再次使用的话将逐次选中其他的行。
--]]
function select_current_frame(subs, sel)
    local num_header_lines = count_header_lines(subs)

    local start_idx = sel[1] or 0
    local cur_time = aegisub.ms_from_frame(aegisub.project_properties().video_position)

    local prev_end_time = 0
    if #sel > 0 then
        prev_end_time = subs[sel[1]].end_time
    end

    local closest_line_idx
    local closest_line_start_time

    for delta = 1, (#subs - 1) do
        local i = (start_idx + delta - 1) % #subs + 1
        if (i > num_header_lines) then
            local line = subs[i]
            local start_time = line.start_time
            local end_time = line.end_time

            if (start_time ~= nil and end_time ~= nil) then

                --        aegisub.log("#subs = %d, delta = %d, i = %d, cur = %d, prev_end = %d, start = %d, end = %d\n",
                --            #subs, delta, i, cur_time, prev_end_time, start_time, end_time)

                if between(cur_time, start_time, end_time) then
                    return {i}
                end

                if between(cur_time, prev_end_time, start_time)
                    and (closest_line_start_time == nil or start_time < closest_line_start_time) then
                    closest_line_idx = i
                    closest_line_start_time = start_time
                end

                prev_end_time = end_time
            end
        end
    end

    if closest_line_idx ~= nil then return {closest_line_idx} else return sel end
end

aegisub.register_macro("0.0/Select current frame", "选中当前视频时间所对应字幕", select_current_frame)

--[[ ============================================================================
-- Add music symbol
--   在中文和英文部分的开头和结尾加上♪符号。
--]]
function add_music_symbol_to_part(str)
    if #str == 0 then return "" end
    local trimmed = str:gsub("^♪", ""):gsub("♪$", ""):trim()
    return "♪ " .. trimmed .. " ♪"
end

function add_music_symbol(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        line.text = combine(
            add_music_symbol_to_part(chn), 
            add_music_symbol_to_part(eng), 
            chn_metadata, 
            eng_metadata
        )
        subs[idx] = line
    end
end

aegisub.register_macro("0.0/Add music symbol", "添加音乐符号", add_music_symbol)

--[[ ============================================================================
-- Lint
--   自动修复一些常见的简单格式问题。
--   有待完善，目前仅有如下功能：
--     1. 将中文部分的一些标点替换为空格。
--     2. 将英文部分中的一些中文标点替换为相对应的英文标点。
--     3. 确保英文部分的一些标点符号之后有空格。
--]]
function lint_chinese(str)
    local punctuations_to_remove = { "！", "？", "，", "。", "：", "；", "%.%.%.", "!", "%?", "," }
    local result = str
    for _, v in ipairs(punctuations_to_remove) do
        result = result:gsub(v, " ")
    end
    return result
end

function lint_english(str)
    local chn_punctuations = { "！", "？", "。", "，" }
    local eng_punctuations = { "!", "?", ".", "," }

    local result = str
    for i, v in ipairs(chn_punctuations) do
        result = result:gsub(v, eng_punctuations[i])
    end
    result = result
            :gsub("(%a)([%.,!?])(%w)", "%1%2 %3")
            :gsub("(%w)([%.,!?])(%a)", "%1%2 %3")
            :gsub("(%d)([!?])(%d)", "%1%2 %3")
    return result
end

function lint(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        line.text = combine(lint_chinese(chn), lint_english(eng), 
            chn_metadata, eng_metadata)
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Lint", "自动修复常见格式问题", lint)

--[[ ============================================================================
-- Fade in at current frame
--   渐入到当前帧。
--   通常用于原视频中有渐变的字幕，需要让我们的字幕和原视频中的字幕同步渐变的场合。
--   这个宏负责自动化"从视频下方找帧数然后写进\fade"的操作，但还是需要手动寻找正确的视频位置。
--   使用方法：
--     1. 首先打好轴。
--     2. 把视频调整到原字幕渐入结束后的第一帧（也就是第一个“完全没有变淡”的帧）。
--     3. 选中需要渐变的字幕，然后使用这个宏。
--
-- Fade out at current frame
--   从当前帧渐出。
--   使用方法同上，把视频调整到原字幕开始渐出的前一帧再使用（最后一个“完全没有变淡”的帧）。
--
-- Remove fade
--   移除\fade。
--]]
function apply_fade(subs, sel, act, mode)
    local cur_time = aegisub.ms_from_frame(aegisub.project_properties().video_position + 1)
    local start_diff = cur_time - subs[act].start_time
    local end_diff = subs[act].end_time - cur_time

    --aegisub.log("cur_time = %d\n, active start = %d\n, active end = %d\n, start_diff = %d\n, end_diff = %d\n",
    --        cur_time, subs[act].start_time, subs[act].end_time, start_diff, end_diff
    --)

    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local in_str, out_str = line.text:match("\\fad%((%d*)[, ]*(%d*)%)")
        local fade_in = 0
        local fade_out = 0
        if in_str ~= nil then fade_in = tonumber(in_str) end
        if out_str ~= nil then fade_out = tonumber(out_str) end
        local cleaned = line.text:gsub("{\\fad%(%d*[, ]*%d*%)}", ""):gsub("\\fad%(%d*[, ]*%d*%)", "")
        if mode == "in" then
            fade_in = start_diff
        elseif mode == "out" then
            fade_out = end_diff
        end

        if mode == "remove" then
            line.text = cleaned
        else
            line.text = string.format("{\\fad(%d,%d)}%s", fade_in, fade_out, cleaned)
        end
        subs[idx] = line
    end

    return sel
end

function fade_in(subs, sel, act)
    return apply_fade(subs, sel, act, "in")
end

function fade_out(subs, sel, act)
    return apply_fade(subs, sel, act, "out")
end

function remove_fade(subs, sel, act)
    return apply_fade(subs, sel, act, "remove")
end

aegisub.register_macro("0.0/Fade in at current frame", "渐入到当前帧", fade_in)
aegisub.register_macro("0.0/Fade out at current frame", "从当前帧渐出", fade_out)
aegisub.register_macro("0.0/Remove fade", "移除渐变", remove_fade)

--[[ ============================================================================
-- Highlight line
--   给选中行添加{\blur10\bord3}。用于字幕背景过浅，需要多加阴影来突出字幕的地方。
--   可以修改代码中的"style"更改使用的tag。
--]]
function apply_highlight(subs, sel)
    local style = "{\\blur10\\bord3}"
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        if not line.text:startsWith(style) then
            line.text = style .. line.text
            subs[idx] = line
        end
    end
    if #sel == 1 then return {sel[1] + 1} else return sel end
end

aegisub.register_macro("0.0/Highlight line", "添加阴影", apply_highlight)

--[[ ============================================================================
-- Multi spaces
--   把中文部分中的空格变为多个连续空格。可以重复使用来切换被更改的空格。用于同一行有两个人说话的字幕。
--   例如：
--     我拿大 你拿小 我全都要\N-半分以上は俺、残りやそっち。 -俺が全部だ！
--   使用之后：
--     我拿大   你拿小 我全都要\N-半分以上は俺、残りやそっち。 -俺が全部だ！
--   再使用一次：
--     我拿大 你拿小   我全都要\N-半分以上は俺、残りやそっち。 -俺が全部だ！
--
--   默认使用三个空格。可以修改代码中的"multi_spaces"来更改空格数量。
--
-- Single space
--   将中文部分的连续空格变为一个空格
--]]
local multi_spaces = "   "
local short_spaces = " "

function apply_multi_spaces(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        local first_multi_space_index = chn:find(multi_spaces)

        local multi_space_group_index = -1
        local temp_search_index = 1
        if first_multi_space_index ~= nil then
            while true do
                local space_index, space_end_index = chn:find(" +", temp_search_index)
                multi_space_group_index = multi_space_group_index + 1
                if space_index == first_multi_space_index then break end
                temp_search_index = space_end_index + 1
            end
        end

        local parts = chn:split(" +", 99999, true)
        if #parts > 1 then
            multi_space_group_index = (multi_space_group_index + 1) % (#parts - 1) + 1

            local new_chn = ""
            for i, v in ipairs(parts) do
                local separator = short_spaces
                if i == (multi_space_group_index + 1) then
                    separator = multi_spaces
                elseif i == 1 then
                    separator = ""
                end

                new_chn = new_chn .. separator .. v
            end
            line.text = combine(new_chn, eng, chn_metadata, eng_metadata)
            subs[idx] = line
        end
    end

    return sel
end

aegisub.register_macro("0.0/Multi spaces", "将中文部分的空格变成多个连续空格", apply_multi_spaces)

function single_space(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local chn, eng = line.text:get_parts()
        line.text = combine(table.concat(chn:split(" +", 99999, true), short_spaces), eng)
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Single space", "将中文部分的所有连续空格变为一个空格", single_space)

--[[ ============================================================================
-- Delete empty lines
--   删除文件中所有空白行
--]]
function delete_empty_lines(subs)
    local first_line = count_header_lines(subs) + 1
    local i = first_line
    while i <= #subs do
        local text = subs[i].text
        if text ~= nil and #(text:trim()) == 0 then subs.delete(i) else i = i + 1 end
    end
    return {first_line}
end

aegisub.register_macro("0.0/Delete empty lines", "删除空白行", delete_empty_lines)

--[[ ============================================================================
-- Duplicate with border
--   复制每个选中行，并把两行字幕放在不同的图层。上层的字幕的\bord会被移除，下层的字幕会带有\bord3。
--   用于需要给有边框的特效字加\blur的情况。如果字幕有边框，则\blur只会模糊边框而不会模糊里面的字，所以有时需要通过双层字幕来实现想要的模糊效果。
--]]
function duplicate_with_border(subs, sel)
    local final_sel = {}
    local diff = 0

    for _, idx in ipairs(sel) do
        local i = idx + diff
        local line = subs[i]
        local text = line.text:gsub("\\bord%d*", "")
        line.text = "{\\bord3}" .. text
        subs.insert(i, line)
        diff = diff + 1
        i = i + 1
        line.layer = line.layer + 1
        line.text = text
        subs[i] = line

        final_sel[#final_sel + 1] = i - 1
        final_sel[#final_sel + 1] = i
    end

    return final_sel
end

aegisub.register_macro("0.0/Duplicate with border", "复制为两个图层并在下层添加边框", duplicate_with_border)

--[[ ============================================================================
-- Save as text file
--  把选中行存为纯文本，方便对比翻译和校对稿。生成的文件会和字幕文件存在同一目录中。
--  生成文件之后可以用 www.diffchecker.com 等工具辅助对比。
--]]

function save_text_file(subs, sel, unify_spaces)
    if #sel == 0 then return end

    local num_header_lines = count_header_lines(subs)

    local file_name = aegisub.file_name():gsub("%.[^%.]*$", "")
        .. "." .. (sel[1] - num_header_lines)
        .. "-" .. (sel[#sel] - num_header_lines)
        .. ".txt"
    local f = io.open(aegisub.decode_path("?script\\" .. file_name), "w")

    local meta, styles = karaskel.collect_head(subs, false)

    for _, idx in ipairs(sel) do
        local line = subs[idx]
        karaskel.preproc_line_text(meta, styles, line)
        if line.text_stripped ~= nil then
            local text = line.text_stripped:trim()
            if unify_spaces then
                text = text:gsub("%s+", " ")
            end
            if #text > 0 then
                f:write(text:gsub("\\N", "\n") .. "\n\n")
            end
        end
    end

    f:close()

    aegisub.log("Saved as \"%s\"\n", file_name)

    return sel
end

aegisub.register_macro("0.0/Save as text file", "存为纯文本文件",
    function (subs, sel) return save_text_file(subs, sel, false) end)

aegisub.register_macro("0.0/Save as text file and unify spaces", "存为纯文本文件，把所有连续空格变为一个空格",
    function (subs, sel) return save_text_file(subs, sel, true) end)

--[[ ============================================================================
-- Add fs30
--]]

function add_fs30(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        if not eng:startsWith("{\\fs30") then eng = "{\\fs30}" .. eng end
        line.text = combine(chn, eng, chn_metadata, eng_metadata)
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Add fs30", "Add fs30", add_fs30)

--[[ ============================================================================
-- Split to frames
--]]

function split_to_frames(subs, sel)
    local offset = 0
    local new_sel = {}
    for _, idx in ipairs(sel) do
        local line = subs[idx + offset]
        local start_frame = aegisub.frame_from_ms(line.start_time)
        local end_frame = aegisub.frame_from_ms(line.end_time)
        for frame = start_frame, end_frame - 1 do
            line.start_time = aegisub.ms_from_frame(frame)
            line.end_time = aegisub.ms_from_frame(frame + 1)
            if frame == start_frame then
                subs[idx + offset] = line
            else
                offset = offset + 1
                subs.insert(idx + offset, line)
            end
            new_sel[#new_sel + 1] = idx + offset
        end
    end
    return new_sel
end

aegisub.register_macro("0.0/Split to frames", "Split to frames", split_to_frames)

--[[ ============================================================================
-- Batch shift
--]]
function batch_shift(subs, sel)
    local anchor_index
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        if line.text:startsWith("@@@") then
            anchor_index = idx
        end
    end

    if anchor_index == nil then anchor_index = sel[1] end
    local cur_time = aegisub.ms_from_frame(aegisub.project_properties().video_position)
    local shift = cur_time - subs[anchor_index].start_time

    for _, idx in ipairs(sel) do
        local line = subs[idx]
        line.start_time = line.start_time + shift
        line.end_time = line.end_time + shift
        subs[idx] = line
    end

    return sel
end

aegisub.register_macro("0.0/Batch shift", "rt", batch_shift)

--[[ ============================================================================
-- Split English and Chinese
--]]
function split_eng_chn(subs, sel)
    local offset = 0
    local new_sel = {}
    for _, idx in ipairs(sel) do
        local real_idx = idx + offset
        local line = subs[real_idx]
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        line.text = chn
        subs[real_idx] = line
        line.text = eng
        subs.insert(real_idx+1, line)
        offset = offset + 1
        new_sel[#new_sel + 1] = real_idx
        new_sel[#new_sel + 1] = real_idx + 1
    end
    return
end

aegisub.register_macro("0.0/Split English and Chinese", "rt", split_eng_chn)

--[[ ============================================================================
-- Snap to frame
--]]
function snap_to_frame(subs, sel)
    for _, idx in ipairs(sel) do
        local line = subs[idx]
        line.start_time = aegisub.ms_from_frame(aegisub.frame_from_ms(line.start_time))
        line.end_time = aegisub.ms_from_frame(aegisub.frame_from_ms(line.end_time))
        subs[idx] = line
    end
    return sel
end

aegisub.register_macro("0.0/Snap to Frame", "rt", snap_to_frame)

--[[ ============================================================================
-- Find all used fonts
--]]
function normalize_font(fontname) 
    if (fontname:sub(1, 1) == "@") then
        return fontname:sub(2, #fontname)
    else 
        return fontname 
    end 
end

function list_fonts(subs, sel)
    local header_lines = count_header_lines(subs)
    local meta, styles = karaskel.collect_head(subs, false)

    local fonts = {}
    for _, style in ipairs(styles) do
        fonts[normalize_font(style.fontname)] = style.name 
    end

    local num_lines = #subs
    for idx = header_lines, num_lines do 
        local line = subs[idx] 
        if line.text ~= nil then 
            for font in line.text:gmatch("\\fn([^\\}]*)") do 
                local normalized = normalize_font(font)
                if fonts[normalized] == nil then
                    fonts[normalized] = idx 
                end
            end 
        end 
    end

    for font, source in pairs(fonts) do 
        aegisub.log("%s (%s)\n", font, source)
    end 

    aegisub.log("\n\n\nWithout source:\n")

    for font in pairs(fonts) do 
        aegisub.log("%s\n", font)
    end 

    return { sel }
end

aegisub.register_macro("0.0/List Fonts", "列出字幕文件中所有使用过的字体", list_fonts)

--[[ ============================================================================
-- Replace English names in Chinese parts
--]]

function nocase(s)
    s = string.gsub(s, "%a", function (c)
          return string.format("[%s%s]", string.lower(c),
                                         string.upper(c))
        end)
    return s
end

function eng_replace_helper(subs, idx, fromName, toName)
    local line = subs[idx]
    if line.text ~= nil then 
        local chn, eng, chn_metadata, eng_metadata = line.text:get_parts()
        local chn_replaced = chn:gsub(fromName, toName)
        if chn ~= chn_replaced then 
            line.text = combine(chn_replaced, eng, chn_metadata, eng_metadata)
            subs[idx] = line
        end
    end
end 

function eng_replace(subs, sel)
    local config = {
        {class="edit", name="from", text="", x=0, y=0, width=25},
        {class="edit", name="to", text="", x=0, y=1, width=25},
        {class="checkbox", name="all_lines", x = 0, y = 2, value=true, label="All lines"}
    }
    local btn, result = aegisub.dialog.display(config)
    if btn then 
        local num_header_lines = count_header_lines(subs)
        local fromName = nocase(result["from"])
        local toName = result["to"]
        if result["all_lines"] then 
            idx = num_header_lines
            while idx < #subs do 
                eng_replace_helper(subs, idx, fromName, toName) 
                idx = idx + 1
            end 
        end 
        for _, idx in ipairs(sel) do 
            eng_replace_helper(subs, idx, fromName, toName)
        end
    end
    return sel 
end

aegisub.register_macro("0.0/Replace English names", "rt", eng_replace)
