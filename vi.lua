---
--- Made in a day based on the built in edit.lua in CC: Tweaked
--- Though unlike edit.lua this features most text manipulation features in the original vi
--- Some of these include undo, redo, clipboard and normal mode commands like w b e l k j h p yy dd
---
--- Please note! To exit NORMAL mode you need to use CTRL+C since ESC closes the gui in CC:Tweaked 
---
--- By Walcriz in June 2024
--- Based off (https://github.com/cc-tweaked/CC-Tweaked/blob/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/programs/edit.lua) with CCPL license (2017 Daniel Ratcliffe)
---

---@diagnostic disable: redefined-local

-- Get the file to edit
local terminalArgs = { ... }
if #terminalArgs == 0 then
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage: " .. programName .. " <path>")
    return
end

-- Check the file exists and is not a directory
local path = shell.resolve(terminalArgs[1])
local readOnly = fs.isReadOnly(path)
if fs.exists(path) and fs.isDir(path) then
    print("Cannot edit a directory.")
    return
end

-- Create .lua files by default
if not fs.exists(path) and not string.find(path, "%.") then
    local extension = settings.get("edit.default_extension")
    if extension ~= "" and type(extension) == "string" then
        path = path .. "." .. extension
    end
end

local modes = {
    insert = "INSERT",
    normal = "NORMAL",
    visual = "VISUAL",
    vline = "V-LINE",
    command = "COMMAND",
    search = "SEARCH",
}

-- Setup
local x, y = 1, 1
local w, h = term.getSize()
local scrollX, scrollY = 0, 0
local mode = modes.normal
local dirty = false
local unsaved = false
local completionDirty = false

local preferredX = nil

local visual_x, visual_y

local prompt = nil

local search = {
    searching = false,
    current = 0,
    results = nil
}

local clipboard = {
    ---@type "text"|"line"|""
    type = "",
    ---@type string|table
    text = ""
}

local commandX = 1
local commandText = ""
local commandHistory = {
    history = {},
    current = 0
}

-- Keys
local ctrlDown = false

-- Used to keep track of how far into an action you are for multi character actions
local actionProgress = {}

local lines = {}
local running = true

local undo_states = {}
local redo_states = {}

-- Colours
local highlightColour, keywordColour, commentColour, textColour, bgColour, stringColour, errorColour, selectionColour
if term.isColour() then
    bgColour = colours.black
    textColour = colours.white
    highlightColour = colours.yellow
    keywordColour = colours.yellow
    commentColour = colours.green
    stringColour = colours.red
    errorColour = colours.red
    selectionColour = colours.grey
else
    bgColour = colours.black
    textColour = colours.white
    highlightColour = colours.lightGrey
    keywordColour = colours.lightGrey
    commentColour = colours.grey
    stringColour = colours.white
    errorColour = colours.white
    selectionColour = colours.lightGrey
end

-- Status/language server info
local status = { ok = true, text = "" }
local function setStatus(text, ok)
    status.text = text
    status.ok = ok
end

if readOnly then
    setStatus("File is read only", false)
elseif fs.getFreeSpace(path) < 1024 then
    setStatus("Disk is low on space", false)
else
    setStatus(mode, true)
end

-- Utilites
local function load(_path)
    lines = {}
    if fs.exists(_path) then
        local file = io.open(_path, "r")
        local sLine = file:read()
        while sLine do
            table.insert(lines, sLine)
            sLine = file:read()
        end
        file:close()
    end

    if #lines == 0 then
        table.insert(lines, "")
    end
end

local function save(_path, _writer)
    -- Create intervening folder
    local sDir = _path:sub(1, _path:len() - fs.getName(_path):len())
    if not fs.exists(sDir) then
        fs.makeDir(sDir)
    end

    -- Save
    local file, fileerr
    local function innerSave()
        file, fileerr = fs.open(_path, "w")
        if file then
            if file then
                _writer(file)
            end
        else
            error("Failed to open " .. _path)
        end
    end

    local ok, err = pcall(innerSave)
    if file then
        file.close()
    end
    return ok, err, fileerr
end

function table.shallow_copy(t)
    local t2 = {}
    for k,v in pairs(t) do
        t2[k] = v
    end
    return t2
end

function table.merge(t1, t2)
    for k,v in pairs(t2) do
        t1[k] = v
    end
    return t1
end

local function getSelectedText() -- TODO: FIX THIS, IT IS VERY BORKEN
    local selectedLines = {}
    if mode == modes.vline then
        local upper = math.min(y, y + visual_y - 1)
        local lower = math.max(y, y + visual_y - 1)
        for i = upper, lower do
            selectedLines[#selectedLines + 1] = lines[i]
        end
    elseif mode == modes.visual then
        local currX, currY = x, y

        if currY > visual_y then
            local tempX, tempY = currX, currY
            currX, currY = visual_x, visual_y
            visual_x, visual_y = tempX, tempY
        end

        if currY == visual_y then
            if currX > visual_x then
                local temp = currX
                currX = visual_x
                visual_x = temp
            end

            selectedLines[1] = string.sub(lines[currY], currX, visual_x)
        else
            -- First and last line in selection needs special treatment

            selectedLines[1] = string.sub(lines[currY], currX)
            for i = currY + 1, visual_y - 1 do
                selectedLines[#selectedLines + 1] = lines[i]
            end
            selectedLines[#selectedLines + 1] = string.sub(lines[visual_y], 1, visual_x)
        end
    end

    return selectedLines
end

local function insideSelection(x, y) -- TODO: FIX THIS, IT IS VERY BORKEN
    if mode == modes.vline then
        local upper = math.min(y, visual_y)
        local lower = math.max(y, visual_y)
        return y >= upper and y <= lower
    elseif mode == modes.visual then
        local currX, currY = x, y

        if currY > visual_y then
            local tempX, tempY = currX, currY
            currX, currY = visual_x, visual_y
            visual_x, visual_y = tempX, tempY
        end

        if currY == visual_y then
            if currX > visual_x then
                local temp = currX
                currX = visual_x
                visual_x = temp
            end

            return currX <= x and x <= visual_x
        else
            -- First and last line in selection needs special treatment
        end
    else
        return false
    end
end

local keywords = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
    ["goto"] = true
}

local written = 0
local function tryWrite(index, line, regex, colour)
    local match = string.match(line, regex)
    if match then
        if type(colour) == "number" then
            term.setTextColour(colour)
        else
            term.setTextColour(colour(match))
        end
        for k = 1, #match do
            local char = match:sub(k,k)
            if insideSelection(index, written + k - 1) then
                term.setBackgroundColour(selectionColour)
            end
            term.write(char)
            term.setBackgroundColour(bgColour)
        end
        -- term.write(match)
        term.setTextColour(textColour)
        written = written + #match + 1
        return string.sub(line, #match + 1)
    end
    return nil
end

local function writeHighlighted(line, index)
    written = 0
    while #line > 0 do
        line =
        tryWrite(index, line, "^%-%-%[%[.-%]%]", commentColour) or
        tryWrite(index, line, "^%-%-.*", commentColour) or
        tryWrite(index, line, "^\"\"", stringColour) or
        tryWrite(index, line, "^\".-[^\\]\"", stringColour) or
        tryWrite(index, line, "^\'\'", stringColour) or
        tryWrite(index, line, "^\'.-[^\\]\'", stringColour) or
        tryWrite(index, line, "^%[%[.-%]%]", stringColour) or
        tryWrite(index, line, "^[%w_]+", function(match)
            if keywords[match] then
                return keywordColour
            end
            return textColour
        end) or
        tryWrite(index, line, "^[^%w_]", textColour)
    end
end

-- Tab Completions
local tabCompletions
local currentCompletion

local tabCompleteEnv = _ENV

local function writeCompletion()
    if currentCompletion then
        local completion = tabCompletions[currentCompletion]
        term.setTextColor(colours.white)
        term.setBackgroundColor(colours.grey)
        term.write(completion)
        term.setTextColor(textColour)
        term.setBackgroundColor(bgColour)
    end
end

local function redrawText()
    local cursorX, cursorY = x, y
    for y = 1, h - 1 do
        term.setCursorPos(1 - scrollX, y)
        term.clearLine()

        local sLine = lines[y + scrollY]
        if sLine ~= nil then
            writeHighlighted(sLine, y + scrollY)
            if cursorY == y and cursorX == #sLine + 1 then
                writeCompletion()
            end
        end
    end
    term.setCursorPos(x - scrollX, y - scrollY)
end

-- Find words in lines and append it to the tabCompletions
local function findWordsInLines(match)
    if #match < 2 then
        return
    end

    currentCompletion = nil
    for index, line in ipairs(lines) do
        if index == y then
            goto continue
        end

        for word in line:gmatch("%w+") do
            -- Word must start with match
            if not match or word:sub(1, #match) == match then
                table.insert(tabCompletions, string.sub(word, #match + 1))
            end
        end
        ::continue::
    end
end

local function complete(line)
    if settings.get("edit.autocomplete") then
        local startPos = string.find(line, "[a-zA-Z0-9_%.:]+$")
        if startPos then
            line = string.sub(line, startPos)
        end
        if #line > 0 then
            tabCompletions = textutils.complete(line, tabCompleteEnv)
            -- Append findWordsInLines results to tabCompletions
            findWordsInLines(line)
            return tabCompletions
        end
    end
    return nil
end

local function recomplete()
    local line = lines[y]
    if not readOnly and x == #line + 1 then
        tabCompletions = complete(line)
        if tabCompletions and #tabCompletions > 0 then
            currentCompletion = 1
        else
            currentCompletion = nil
        end
    else
        tabCompletions = nil
        currentCompletion = nil
    end
end


local function redrawLine(_nY)
    local sLine = lines[_nY]
    if sLine then
        term.setCursorPos(1 - scrollX, _nY - scrollY)
        term.clearLine()
        writeHighlighted(sLine, _nY)
        if _nY == y and x == #sLine + 1 then
            writeCompletion()
        end
        term.setCursorPos(x - scrollX, _nY - scrollY)
    end
end

local function stringifyAction()
    local text = ""
    for _, value in ipairs(actionProgress) do
        if type(value) == "string" then
            text = text .. value
        elseif type(value) == "number" then
            text = "<" .. value .. ">"
        end

        -- setStatus("Going deeper ..>> " .. type(value) .. " <<>> " .. #actionText, true)
    end

    return text
end

-- Command line
local function redrawCommandLine()
    -- Clear line
    term.setCursorPos(1, h)
    term.clearLine()

    if mode == modes.command then
        if prompt then
            term.write(prompt.text)
            return
        end
        -- Draw
        term.setTextColour(textColour)
        term.write(search.searching and "/" or ":")
        term.write(commandText)
        term.setCursorPos(commandX + 1, h)
    else
        -- Draw status
        term.setTextColour(status.ok and highlightColour or errorColour)
        term.write(status.text)
        term.setTextColour(textColour)

        -- Draw line numbers
        local actionReadable = stringifyAction()
        term.setCursorPos(w - #("Ln " .. y) - #(actionReadable .. " ") + 1, h)
        term.setTextColour(textColour)
        term.write(actionReadable .. " ")
        term.setTextColour(highlightColour)
        term.write("Ln ")
        term.setTextColour(textColour)
        term.write(y)

        -- Reset cursor
        term.setCursorPos(x - scrollX, y - scrollY)
    end
end

local function setPrompt(text, buttons)
    if text == nil then
        mode = modes.normal
        prompt = nil
        redrawCommandLine()
        return
    end

    prompt = {
        text = text,
        buttons = buttons,
    }
    mode = modes.command
    redrawCommandLine()
end

local commands
commands = {
    ["w"] = function() -- Save
        if readOnly then
            setStatus("Access denied", false)
        else
            local ok, _, fileerr  = save(path, function(file)
                for _, line in ipairs(lines) do
                    file.write(line .. "\n")
                end
            end)
            if ok then
                setStatus("Saved to " .. path, true)
            else
                if fileerr then
                    setStatus("Error saving: " .. fileerr, false)
                else
                    setStatus("Error saving to " .. path, false)
                end
            end

            unsaved = false
        end

        redrawCommandLine()
    end,
    ["q"] = function() -- Quit
        if #undo_states > 0 and not readOnly and unsaved then
            setPrompt("Save changes? [Y]es [N]o [C]ancel", {
                y = function()
                    commands["w"]()
                    running = false
                end,
                n = function()
                    running = false
                end,
                c = function()
                    setPrompt(nil)
                end
            })
        else
            running = false
        end
    end,
    ["wq"] = function() -- Save and quit
        commands["w"]()
        commands["q"]()
    end,
}

local function setCursor(newX, newY)
    if newY > #lines then
        newY = #lines
    end

    if newY < 1 then
        newY = 1
    end

    -- try to maintain x when changing y via preferredX
    -- TODO: Fix
    if preferredX and newX < preferredX and newY ~= y then
        newX = preferredX
        preferredX = nil
    elseif not preferredX and newX < x then
        preferredX = newX
    end

    if mode == modes.insert then
        if newX > #lines[newY] + 1 then
            newX = #lines[newY] + 1
        end
    else
        if newX > #lines[newY] then
            newX = #lines[newY]
        end
    end

    if newX < 1 then
        newX = 1
    end

    local _, oldY = x, y
    x, y = newX, newY
    local screenX = x - scrollX
    local screenY = y - scrollY

    local redraw = false
    if screenX < 1 then
        scrollX = x - 1
        screenX = 1
        redraw = true
    elseif screenX > w then
        scrollX = x - w
        screenX = w
        redraw = true
    end

    if screenY < 1 then
        scrollY = y - 1
        screenY = 1
        redraw = true
    elseif screenY > h - 1 then
        scrollY = y - (h - 1)
        screenY = h - 1
        redraw = true
    end

    if mode == modes.visual or mode == modes.vline then
        redrawText()
    else
        recomplete()
        if redraw then
            redrawText()
        elseif y ~= oldY then
            redrawLine(oldY)
            redrawLine(y)
        else
            redrawLine(y)
        end
    end
    term.setCursorPos(screenX, screenY)

    redrawCommandLine()
end

---Yank text to the clipboard
---@param text string|table
---@param type "text"|"line"
local function yank(text, type)
    clipboard = {
        type = type,
        text = text
    }
end

local function snapshot()
    unsaved = true
    if mode == modes.insert then
        dirty = true
    end
    undo_states[#undo_states + 1] = {
        x = x,
        y = y,
        lines = table.shallow_copy(lines)
    }
end

---Paste clipboard
---@param direction "up"|"down"
local function paste(direction)
    snapshot()

    if clipboard.type == "line" then
        if direction == "up" then
            if type(clipboard.text) == "table" then
                for _, line in ipairs(clipboard.text) do -- TODO: this needs to be reversed
                    table.insert(lines, y, line)
                end
            else
                table.insert(lines, y, clipboard.text)
            end
        else
            if type(clipboard.text) == "table" then
                for _, line in ipairs(clipboard.text) do
                    table.insert(lines, y + 1, line)
                    setCursor(x, y + 1)
                end
            else
                table.insert(lines, y + 1, clipboard.text)
                setCursor(x, y + 1)
            end
        end
    elseif clipboard.type == "text" then
        -- Insert text into current line
        lines[y] = string.sub(lines[y], 1, x) .. clipboard.text .. string.sub(lines[y], x + 1)
        setCursor(x + #clipboard.text, y)
    end
    redrawText()
end

local function undo()
    if #undo_states > 0 then
        redo_states[#redo_states + 1] = {
            x = x,
            y = y,
            lines = table.shallow_copy(lines)
        }
        local state = undo_states[#undo_states]
        lines = table.shallow_copy(state.lines)
        undo_states[#undo_states] = nil
        setCursor(state.x, state.y)
    end
end

local function redo()
    if #redo_states > 0 then
        undo_states[#undo_states + 1] = {
            x = x,
            y = y,
            lines = table.shallow_copy(lines)
        }
        local state = redo_states[#redo_states]
        lines = table.shallow_copy(state.lines)
        redo_states[#redo_states] = nil
    end
end

local function isAtEndOfFile()
    return y == #lines and x == #lines[y]
end

local function isJumpStop(char)
    return char == "(" or char == ")"
        or char == "[" or char == "]"
        or char == "{" or char == "}"
        or char == "<" or char == ">"
        or char == "|"
        or char == ","
        or char == ";"
        or char == ":"
        or char == "."
        or char == "?"
        or char == "/"
        or char == "\\"
        or char == "*"
        or char == "+"
        or char == "-"
        or char == "="
end

local function searchAndReplace(pattern)
    local prefix, search, replace, suffix = pattern:match("^(%%?s)/(.-)/(.-)/?(g?)$")

    if not prefix then
        setStatus("Invalid pattern format")
        redrawCommandLine()
        return
    end

    snapshot()

    -- Helper function to replace the first occurrence
    local function replaceFirst(str, search, replace)
        local startPos, endPos = str:find(search)
        if not startPos then
            return str
        end
        return str:sub(1, startPos - 1) .. replace .. str:sub(endPos + 1)
    end

    -- Helper function to replace all occurrences
    local function replaceAll(str, search, replace)
        return str:gsub(search, replace)
    end

    if prefix == "%s" then
        -- Replace on all lines
        for i = 1, #lines do
            if suffix == "g" then
                lines[i] = replaceAll(lines[i], search, replace)
            else
                lines[i] = replaceFirst(lines[i], search, replace)
            end
        end
        redrawText()
    else
        -- Replace on the current line
        if suffix == "g" then
            lines[y] = replaceAll(lines[y], search, replace)
        else
            lines[y] = replaceFirst(lines[y], search, replace)
        end
        redrawLine(y)
    end
end

function search:searchLines(text)
    text = string.gsub(text, "%(", "%%(")
    text = string.gsub(text, "%)", "%%)")
    text = string.gsub(text, "%[", "%%[")
    text = string.gsub(text, "%]", "%%]")

    search.results = {}
    local current = 1
    for i = 1, #lines do
        local s
        local function find()
            s, _ = string.find(lines[i], text)
        end

        if not pcall(find) then
            setStatus("Invalid lua pattern!", false)
            redrawCommandLine()
            return true
        end

        if s then
            search.results[#search.results + 1] = { y = i, x = s }
            if ((y == i and x < s) or i > y) and current == 1 then
                current = #search.results
            end
        end
    end

    if #search.results == 0 then
        search.results = nil
    else
        search.current = current
    end

    return false
end

function search:next()
    if search.results then
        search.current = search.current + 1
        if search.current > #search.results then
            search.current = 1
        end
        y = search.results[search.current].y
        x = search.results[search.current].x
        setCursor(x, y)
    end
end

function search:previous()
    if search.results then
        search.current = search.current - 1
        if search.current < 1 then
            search.current = #search.results
        end
        y = search.results[search.current].y
        x = search.results[search.current].x
        setCursor(x, y)
    end
end

function commandHistory:next()
    if #self.history > 0 then
        self.current = self.current + 1
        if self.current > #self.history then
            self.current = 0
        end
        if self.current == 0 then
            commandText = ""
        else
            commandText = self.history[self.current]
        end
        commandX = #commandText + 1
        redrawCommandLine()
    end
end

function commandHistory:previous()
    if #self.history > 0 then
        self.current = self.current - 1
        if self.current < 0 then
            self.current = #self.history
        end
        if self.current == 0 then
            commandText = ""
        else
            commandText = self.history[self.current]
        end
        commandX = #commandText + 1
        redrawCommandLine()
    end
end

function commandHistory:append(text)
    if text ~= "" and self.history[#self.history] ~= text then
        self.history[#self.history + 1] = text
    end
    self.current = 0
end

local function getNextWord()
    local wasSpace = false
    local cut = string.sub(lines[y], x + 1, x + 1)
    local startX = x
    local endX = x

    if string.sub(lines[y], x, x) == " " then
        wasSpace = true
        while string.sub(lines[y], endX + 2, endX + 2) == " " do
            endX = endX + 1
        end
    end

    while true do
        if wasSpace and cut ~= " " then
            break
        end

        if isJumpStop(cut) and startX ~= endX then
            break
        end

        if isAtEndOfFile() then
            break
        end

        if endX >= #lines[y] then
            break
        else
            endX = endX + 1

            if cut == " " then
                wasSpace = true
            end
        end

        cut = string.sub(lines[y], endX + 1, endX + 1)
    end

    return startX, endX
end

local function getPreviousWord()
    local cut = string.sub(lines[y], x - 1, x - 1)
    local startX = x - 1
    local endX = x - 1
    if cut == " " then
        startX = startX - 1
        cut = string.sub(lines[y], x - 1, x - 1)
    end

    while true do
        if cut == " " then
            break
        end

        if isJumpStop(cut) and startX ~= endX then
            break
        end

        if startX == 1 then
            break
        else
            startX = startX - 1
        end

        cut = string.sub(lines[y], startX - 1, startX - 1)
    end

    return startX, endX
end

local function getNextEndOfWord()
    local cut = string.sub(lines[y], x + 1, x + 1)
    local startX = x
    local endX = x
    if cut == " " then
        endX = endX + 1
        cut = string.sub(lines[y], endX + 1, endX + 1)
    end

    while true do
        if cut == " " then
            break
        end

        if isJumpStop(cut) and startX ~= endX then
            break
        end

        if isAtEndOfFile() then
            break
        end

        if endX >= #lines[y] then
            break
        else
            endX = endX + 1
        end

        cut = string.sub(lines[y], endX + 1, endX + 1)
    end

    setStatus("Yanked: start: " .. startX .. " end: " .. endX, true)
    redrawCommandLine()
    return startX, endX
end

local function acceptCompletion()
    if currentCompletion then
        -- Append the completion
        local completion = tabCompletions[currentCompletion]
        lines[y] = lines[y] .. completion
        setCursor(x + #completion , y)
    end
end

local movement_actions = {
    -- Movement
    [ keys.left ] = function() setCursor(x - 1, y) end,
    [ keys.right ] = function() setCursor(x + 1, y) end,
    [ keys.up ] = function() setCursor(x, y - 1) end,
    [ keys.down ] = function() setCursor(x, y + 1) end,
    [ "h" ] = function() setCursor(x - 1, y) end,
    [ "j" ] = function() setCursor(x, y + 1) end,
    [ "k" ] = function() setCursor(x, y - 1) end,
    [ "l" ] = function() setCursor(x + 1, y) end,
    [ keys.backspace ] = function() setCursor(x - 1, y) end,
    [ keys.enter ] = function() setCursor(x + 1, y) end,
    [ "{" ] = function() -- Find a line upwards that is empty or only has whitespace
        for i = y - 1, 1, -1 do
            if not string.find(lines[i], "%S") or i == 1 then
                setCursor(x, i)
                break
            end
        end
    end,
    [ "}" ] = function() -- Find a line downwards that is empty or only has whitespace
        for i = y + 1, #lines do
            if not string.find(lines[i], "%S") or i == #lines then
                setCursor(x, i)
                break
            end
        end
    end,

    [ "w" ] = function() -- Word jump to the start of the next word
        local wasSpace = false
        local cut = string.sub(lines[y], x, x)
        local startX = x
        while true do
            if wasSpace and cut ~= " " then
                break
            end

            if isJumpStop(cut) and startX ~= x then
                break
            end

            if isAtEndOfFile() then
                break
            end

            if x >= #lines[y] then
                wasSpace = true
                y = y + 1
                x = 1
                startX = -1
                while string.sub(lines[y + 1], x, x) == " " do
                    x = x + 1
                end
            else
                x = x + 1

                if cut == " " then
                    wasSpace = true
                end
            end

            cut = string.sub(lines[y], x, x)
        end

        setCursor(x, y)
    end,
    [ "e" ] = function() -- Word jump to the end of the next word
        local cut = string.sub(lines[y], x + 1, x + 1)
        local startX = x
        if cut == " " then
            x = x + 1
            cut = string.sub(lines[y], x + 1, x + 1)
        end

        while true do
            if cut == " " then
                break
            end

            if isJumpStop(cut) and startX ~= x then
                break
            end

            if isAtEndOfFile() then
                break
            end

            if x >= #lines[y] then
                y = y + 1
                x = 1
                startX = -1
                while string.sub(lines[y + 1], x, x) == " " do
                    x = x + 1
                end
            else
                x = x + 1
            end

            cut = string.sub(lines[y], x + 1, x + 1)
        end

        setCursor(x, y)
    end,
    [ "b" ] = function() -- Word jump to the start of the previous word
        local cut = string.sub(lines[y], x - 1, x - 1)
        local startX = x
        if cut == " " then
            x = x - 1
            cut = string.sub(lines[y], x - 1, x - 1)
        end

        while true do
            if cut == " " then
                break
            end

            if isJumpStop(cut) and startX ~= x then
                break
            end

            if x == 1 and y == 1 then
                break
            end

            if x == 1 then
                y = y - 1
                x = #lines[y]
                startX = -1
                while string.sub(lines[y - 1], x, x) == " " do
                    x = x - 1
                end
            else
                x = x - 1
            end

            cut = string.sub(lines[y], x - 1, x - 1)
        end

        setCursor(x, y)
    end,

    [ "W" ] = function()
        local wasSpace = false
        local cut = string.sub(lines[y], x, x)
        while true do
            if wasSpace and cut ~= " " then
                break
            end

            if isAtEndOfFile() then
                break
            end

            if x >= #lines[y] then
                wasSpace = true
                y = y + 1
                x = 1
                while string.sub(lines[y + 1], x, x) == " " do
                    x = x + 1
                end
            else
                x = x + 1

                if cut == " " then
                    wasSpace = true
                end
            end

            cut = string.sub(lines[y], x, x)
        end

        setCursor(x, y)
    end,
    [ "E" ] = function()
        local cut = string.sub(lines[y], x + 1, x + 1)
        if cut == " " then
            x = x + 1
            cut = string.sub(lines[y], x + 1, x + 1)
        end

        while true do
            if cut == " " then
                break
            end

            if isAtEndOfFile() then
                break
            end

            if x >= #lines[y] then
                y = y + 1
                x = 1
                while string.sub(lines[y + 1], x, x) == " " do
                    x = x + 1
                end
            else
                x = x + 1
            end

            cut = string.sub(lines[y], x + 1, x + 1)
        end

        setCursor(x, y)
    end,
    [ "B" ] = function()
        local cut = string.sub(lines[y], x - 1, x - 1)
        if cut == " " then
            x = x - 1
            cut = string.sub(lines[y], x - 1, x - 1)
        end

        while true do
            if cut == " " then
                break
            end

            if x == 1 and y == 1 then
                break
            end

            if x == 1 then
                y = y - 1
                x = #lines[y]
                while string.sub(lines[y - 1], x, x) == " " do
                    x = x - 1
                end
            else
                x = x - 1
            end

            cut = string.sub(lines[y], x - 1, x - 1)
        end

        setCursor(x, y)
    end,

    -- Special keybindings under g
    [ "g" ] = {
        [ "g" ] = function() setCursor(1, 1) end, -- Go to top of file
    },

    [ "G" ] = function() setCursor(#lines[#lines], #lines) end, -- Go to bottom of file
}

-- Actions
local actions = {
    [ modes.normal ] = {
        [ "i" ] = function()
            if readOnly then
                return
            end
            mode = modes.insert
            setStatus("INSERT", true)
            redrawCommandLine()
        end,
        [ "a" ] = function()
            if readOnly then
                return
            end
            mode = modes.insert
            setCursor(x + 1, y)
            setStatus("INSERT", true)
            redrawCommandLine()
        end,
        [ "A" ] = function()
            if readOnly then
                return
            end
            mode = modes.insert
            setCursor(#lines[y] + 1, y)
            setStatus("INSERT", true)
            redrawCommandLine()
        end,
        [ "I" ] = function()
            if readOnly then
                return
            end
            mode = modes.insert
            -- Ignore whitespace
            x = 1
            while string.sub(lines[y], x, x) == " " do
                x = x + 1
            end
            setCursor(x, y)
            setStatus("INSERT", true)
            redrawCommandLine()
        end,
        [ "s" ] = function()
            -- delete character at cursor and go into insert mode
            if readOnly then
                return
            end
            snapshot()
            lines[y] = string.sub(lines[y], 1, x - 1) .. string.sub(lines[y], x + 1)
            setCursor(x, y)
            mode = modes.insert
            redrawLine(y)
        end,
        [ "S" ] = function() -- Delete line and enter insert mode
            if readOnly then
                return
            end

            snapshot()
            local line = lines[y]
            local _, spaces = string.find(line, "^[ ]+")
            if not spaces then
                spaces = 0
            end
            lines[y] = string.sub(line, 1, spaces)
            mode = modes.insert
            setCursor(spaces + 1, y)
            redrawLine(y)
        end,
        [ "x" ] = function()
            -- delete character at cursor
            if readOnly then
                return
            end
            snapshot()
            lines[y] = string.sub(lines[y], 1, x - 1) .. string.sub(lines[y], x + 1)
            redrawLine(y)
        end,
        [ "X" ] = function()
            -- delete character at cursor
            if readOnly then
                return
            end
            snapshot()
            lines[y] = string.sub(lines[y], 1, x - 2) .. string.sub(lines[y], x)
            setCursor(x - 1, y)
            redrawLine(y)
        end,
        [ "o" ] = function() -- Open new line
            if readOnly then
                return
            end
            snapshot()
            local line = lines[y]
            local _, spaces = string.find(line, "^[ ]+")
            if not spaces then
                spaces = 0
            end
            table.insert(lines, y + 1, string.rep(' ', spaces))
            setCursor(spaces + 1, y + 1)
            mode = modes.insert
            redrawText()
        end,
        [ "O" ] = function() -- Open new line above
            if readOnly then
                return
            end
            snapshot()
            local line = lines[y]
            local _, spaces = string.find(line, "^[ ]+")
            if not spaces then
                spaces = 0
            end
            table.insert(lines, y, string.rep(' ', spaces))
            setCursor(spaces + 1, y)
            mode = modes.insert
            redrawText()
        end,

        -- Enter visual mode
        -- [ "v" ] = function() -- NOTE: Disabled, they are currently very broken
        --     mode = modes.visual
        --     visual_x = x
        --     visual_y = y
        --     setStatus("VISUAL", true)
        -- end,
        -- [ "V" ] = function()
        --     mode = modes.vline
        --     visual_x = 1
        --     visual_y = y
        --     setStatus("V-LINE", true)
        -- end,

        [ "u" ] = function() -- Undo
            undo()
            redrawText()
        end,

        -- Yank key
        [ "y" ] = {
            [ "y" ] = function() -- Yank line
                yank(lines[y], "line")
                setCursor(x, y)
                redrawText()
            end,
            [ "w" ] = function() -- Yank word
                local startX, endX = getNextWord()
                yank(string.sub(lines[y], startX, endX), "text")
            end,
            [ "b" ] = function() -- Yank word
                local startX, endX = getPreviousWord()
                yank(string.sub(lines[y], startX, endX), "text")
            end,
            [ "e" ] = function() -- Yank word
                local startX, endX = getNextEndOfWord()
                yank(string.sub(lines[y], startX, endX), "text")
            end
        },

        -- Delete key
        [ "d" ] = {
            [ "d" ] = function() -- Delete line
                if not readOnly then
                    snapshot()
                    yank(lines[y], "line")
                    lines[y] = ""
                    table.remove(lines, y)
                    if #lines == 1 then
                        setCursor(1, 1)
                    else
                        setCursor(x, y)
                    end
                    recomplete()
                    redrawText()
                end
            end,
            [ "w" ] = function() -- Delete word
                if not readOnly then
                    local startX, endX = getNextWord()

                    snapshot()
                    yank(string.sub(lines[y], startX, endX), "text")
                    lines[y] = string.sub(lines[y], 1, startX - 1) .. string.sub(lines[y], endX + 1)
                    setCursor(startX, y)
                    recomplete()
                    redrawText()
                end
            end,
            [ "b" ] = function() -- Delete word
                if not readOnly then
                    local startX, endX = getPreviousWord()

                    snapshot()
                    yank(string.sub(lines[y], startX, endX), "text")
                    lines[y] = string.sub(lines[y], 1, startX - 1) .. string.sub(lines[y], endX + 1)
                    setCursor(startX, y)
                    recomplete()
                    redrawText()
                end
            end,
            [ "e" ] = function() -- Delete this line
                if not readOnly then
                    local startX, endX = getNextEndOfWord()

                    snapshot()
                    yank(string.sub(lines[y], startX, endX), "text")
                    lines[y] = string.sub(lines[y], 1, startX - 1) .. string.sub(lines[y], endX + 1)
                    setCursor(startX, y)
                    recomplete()
                    redrawText()
                end
            end,
            [ "j" ] = function() -- Delete this line and the line under
                if not readOnly then
                    snapshot()
                    yank({ lines[y], lines[y + 1] }, "line")
                    table.remove(lines, y)
                    table.remove(lines, y)
                    setCursor(x, y)
                    redrawText()
                end
            end,
            [ "k" ] = function () -- Delete this line and the line above + move cursor up one
                if not readOnly then
                    snapshot()
                    yank({ lines[y - 1], lines[y] }, "line")
                    table.remove(lines, y - 1)
                    table.remove(lines, y - 1)
                    setCursor(x, y - 1)
                    redrawText()
                end
            end
        },

        [ ":" ] = function()
            mode = modes.command
            commandX = 1
            commandText = ""
            redrawCommandLine()
            return true
        end,

        [ "/" ] = function()
            mode = modes.command
            search.searching = true
            redrawCommandLine()
            return true
        end,

        [ "p" ] = function()
            if not readOnly then
                paste("down")
            end
        end,
        [ "P" ] = function()
            if not readOnly then
                paste("up")
            end
        end,

        -- Navigate search results
        [ "n" ] = function()
            search:next()
        end,
        [ "N" ] = function()
            search:previous()
        end
    },

    [ modes.insert ] = {
        -- Movement
        [ keys.left ] = function() setCursor(x - 1, y) end,
        [ keys.right ] = function() setCursor(x + 1, y) end,
        [ keys.up ] = function() setCursor(x, y - 1) end,
        [ keys.down ] = function() setCursor(x, y + 1) end,
        [ keys.backspace ] = function()
            if not dirty then
                snapshot()
            end

            if x > 1 then
                -- Remove character
                local sLine = lines[y]
                if x > 4 and string.sub(sLine, x - 4, x - 1) == "    " and not string.sub(sLine, 1, x - 1):find("%S") then
                    lines[y] = string.sub(sLine, 1, x - 5) .. string.sub(sLine, x)
                    setCursor(x - 4, y)
                else
                    lines[y] = string.sub(sLine, 1, x - 2) .. string.sub(sLine, x)
                    setCursor(x - 1, y)
                end
            elseif y > 1 then
                -- Remove newline
                local sPrevLen = #lines[y - 1]
                lines[y - 1] = lines[y - 1] .. lines[y]
                table.remove(lines, y)
                setCursor(sPrevLen + 1, y - 1)
                redrawText()
            end
        end,
        [ keys.enter ] = function()
            if not dirty then
                snapshot()
            end

            -- Newline
            local line = lines[y]
            local _, spaces = string.find(line, "^[ ]+")
            if not spaces then
                spaces = 0
            end
            lines[y] = string.sub(line, 1, x - 1)
            table.insert(lines, y + 1, string.rep(' ', spaces) .. string.sub(line, x))
            setCursor(spaces + 1, y + 1)
            redrawText()
        end,
        [ keys.tab ] = function()
            -- Accept completion
            if not dirty then
                snapshot()
            end
            acceptCompletion()
            completionDirty = false
            redrawText()
        end
    },

    [ modes.command ] = {
        [ keys.left ] = function()
            commandX = commandX - 1
            redrawCommandLine()
        end,
        [ keys.right ] = function()
            commandX = commandX + 1
            redrawCommandLine()
        end,
        [ keys.up ] = function()
            commandHistory:previous()
        end,
        [ keys.down ] = function()
            commandHistory:next()
        end,
        [ keys.backspace ] = function()
            if commandX == 1 then
                mode = modes.normal
                commandText = ""
                commandX = 1
                search.searching = false
                redrawCommandLine()
                return
            end
            commandText = string.sub(commandText, 1, commandX - 2) .. string.sub(commandText, commandX)
            commandX = commandX - 1
            redrawCommandLine()
        end,
        [ keys.enter ] = function() -- Confirm
            mode = modes.normal

            if search.searching then
                search.searching = false
                search.text = commandText
                local err = search:searchLines(search.text)
                if search.results and #search.results > 0 then
                    local result = search.results[search.current]
                    setStatus("Found " .. #search.results .. " results", true)
                    setCursor(result.x, result.y)
                elseif not err then
                    setStatus("Pattern not found", false)
                end
            else
                commandHistory:append(commandText)
                if tonumber(commandText) then
                    local number = tonumber(commandText)
                    if number > #lines then
                        number = #lines
                    end
                    setCursor(x, number)
                else
                    local prefix = commandText:match("^(%%?s)")

                    if prefix then
                        searchAndReplace(commandText)
                    else
                        local func = commands[commandText]
                        if func then
                            func()
                        else
                            setStatus("Unknown command: " .. commandText, false)
                        end
                    end
                end
            end

            commandText = ""
            commandX = 1
            commandHistory.current = 0
            redrawCommandLine()
        end
    },

    [ modes.visual ] = {
        [ "v" ] = function()
            mode = modes.normal
            redrawText()
            setStatus("NORMAL", true)
            redrawCommandLine()
        end,
    },

    [ modes.vline ] = {
        [ "v" ] = function()
            mode = modes.normal
            redrawText()
            setStatus("NORMAL", true)
            redrawCommandLine()
        end,
    }
}

-- Insert movement_actions into modes.normal visual and vline
table.merge(actions[modes.normal], movement_actions)
table.merge(actions[modes.visual], movement_actions)
table.merge(actions[modes.vline], movement_actions)

local function getAction()
    local currentPath = actions[mode]
    local multiplier = 1
    for _, value in ipairs(actionProgress) do
        if type(value) == "string" and mode ~= modes.command and mode ~= modes.insert then
            local number = tonumber(value)
            if number then
                multiplier = multiplier * 10 + number
                goto continue
            end
        end

        if currentPath[value] == nil then
            -- We found nothing here
            return false, 0, nil
        end

        -- Go deeper
        if type(currentPath[value]) == "function" then
            -- We found a function
            return true, multiplier, currentPath[value]
        end

        currentPath = currentPath[value]
        -- setStatus(value, true)
        ::continue::
        redrawCommandLine()
    end

    return false, 0, currentPath
end

-- returns if action was found, and will run the action if it is present
local function checkActions(key)
    actionProgress[#actionProgress + 1] = key

    local found, multiplier, func = getAction()
    if found and func then
        actionProgress = {}
        for _ = 1, multiplier do
            func()
        end
        -- setStatus("Reset: " .. key, false)
        -- redrawCommandLine()
        return true
    elseif func == nil then
        actionProgress = {}
        -- setStatus("Invalid action: " .. key, false)
        -- redrawCommandLine()
        return false
    end

    -- stringifyAction()
    -- setStatus("No reset: " .. before .. " > " .. after .. " > " .. #actionProgress, true)
    -- redrawCommandLine()
    return true
end

-- Start of program
load(path)

term.setBackgroundColor(bgColour)
term.clear()
term.setCursorPos(x, y)
term.setCursorBlink(true)

recomplete()
redrawText()
redrawCommandLine()

local function handleKey(key)
    if mode ~= modes.normal then
        if key == keys.c and ctrlDown then
            dirty = false
            if mode == modes.insert then
                setCursor(x - 1, y)
            end
            if prompt then
                setPrompt(nil)
            end
            search.searching = false
            mode = modes.normal
            redrawText()
            setStatus("NORMAL", true)
            if mode ~= modes.command then
                redrawCommandLine()
            end
            return
        end
    end

    if mode == modes.normal then
        if ctrlDown then
            if key == keys.r then
                redo()
                redrawText()
            elseif key == keys.n then
                setCursor(x, y + 1)
                redrawText()
            elseif key == keys.p then
                setCursor(x, y - 1)
                redrawText()
            end
        end
    end

    if mode == modes.command then
        if ctrlDown then
            if key == keys.n then
                commandHistory:next()
            elseif key == keys.p then
                commandHistory:previous()
            end
        end
    end

    if mode == modes.insert then
        if ctrlDown then
            if key == keys.n then
                if currentCompletion then
                    -- Next completion
                    currentCompletion = currentCompletion + 1
                    if currentCompletion > #tabCompletions then
                        currentCompletion = 1
                    end
                    completionDirty = true
                    redrawLine(y)
                end
            end

            if key == keys.p then
                if currentCompletion then
                    -- Previous completion
                    currentCompletion = currentCompletion - 1
                    if currentCompletion < 1 then
                        currentCompletion = #tabCompletions
                    end
                    completionDirty = true
                    redrawLine(y)
                end
            end
        end
    end

    if (key > -1 and key < 10) or (key > 64 and key < 91) then
        return
    end

    checkActions(key)
    -- if not checkActions(key) then
    --     -- setStatus(key, true)
    --     -- redrawCommandLine()
    --     -- setStatus(mode, true)
    -- end
end

local function handleChar(char)
    if not checkActions(char) then
        if mode == modes.insert then
            if not dirty then
                snapshot()
            end

            -- Input text
            if completionDirty then
                acceptCompletion()
                completionDirty = false
            end

            local line = lines[y]
            lines[y] = string.sub(line, 1, x - 1) .. char .. string.sub(line, x)
            setCursor(x + 1, y)
        end

        if mode == modes.command then
            if prompt then
                local button = prompt.buttons[char]
                if button then
                    button()
                    setPrompt(nil)
                end
                return
            end
            commandText = string.sub(commandText, 1, commandX - 1) .. char .. string.sub(commandText, commandX)
            commandX = commandX + 1
            redrawCommandLine()
        end
    end
end

-- Program Loop
while running do
    local event, param, param2, param3 = os.pullEvent()
    -- setStatus(event .. " :: " .. param .. " >> " .. mode, true)
    -- redrawCommandLine()
    if event == "key" then
        if param == keys.leftCtrl then
            ctrlDown = true
        end
        handleKey(param)
    elseif event == "char" then
        handleChar(param)
    elseif event == "key_up" then
        if param == keys.leftCtrl then
            ctrlDown = false
        end
    elseif event == "term_resize" then
        w, h = term.getSize()
        setCursor(x, y)
        redrawCommandLine()
        redrawText()
    elseif event == "mouse_click" then
        if mode == modes.command and prompt then
            return -- Ignore clicks when we are prompting user for something
        end

        local cx, cy = param2, param3
        if param == 1 then
            -- Left click
            if mode == modes.command then
                commandX = 1
                commandText = ""
                search.searching = false
                mode = modes.normal
            end

            if cy < h then
                local newY = math.min(math.max(scrollY + cy, 1), #lines)
                local newX = math.min(math.max(scrollX + cx, 1), #lines[newY] + 1)
                setCursor(newX, newY)
            end
        end
    elseif event == "mouse_scroll" then
        if param == -1 then
            -- Scroll up
            if scrollY > 0 then
                -- Move cursor up
                scrollY = scrollY - 1
                redrawText()
            end
        elseif param == 1 then
            -- Scroll down
            local nMaxScroll = #lines - (h - 1)
            if scrollY < nMaxScroll then
                -- Move cursor down
                scrollY = scrollY + 1
                redrawText()
            end
        end
    end
end

-- Cleanup
term.clear()
term.setCursorBlink(false)
term.setCursorPos(1, 1)
