-- Template Rendering Engine for OpsAPI
-- Supports Liquid/Mustache-style syntax with sandboxed execution
-- Usage: local TemplateRenderer = require("lib.template-renderer")

local TemplateRenderer = {}

-- Constants
local MAX_LOOP_ITERATIONS = 1000
local MAX_TEMPLATE_SIZE = 500 * 1024  -- 500KB

-- ============================================================================
-- Utility Functions
-- ============================================================================

--- HTML-escape a string to prevent XSS
-- @param str string The raw string
-- @return string The escaped string
local function html_escape(str)
    if str == nil then return "" end
    str = tostring(str)
    str = str:gsub("&", "&amp;")
    str = str:gsub("<", "&lt;")
    str = str:gsub(">", "&gt;")
    str = str:gsub('"', "&quot;")
    str = str:gsub("'", "&#39;")
    return str
end

--- Trim whitespace from both ends of a string
-- @param s string
-- @return string
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

--- Resolve a dotted path (e.g. "invoice.items[1].description") against a data table
-- @param data table The root context
-- @param path string Dotted path with optional array indices
-- @return any The resolved value or nil
local function resolve(data, path)
    if data == nil or path == nil or path == "" then return nil end
    local current = data

    -- Split on dots, but also handle bracket notation like items[1]
    for segment in path:gmatch("[^%.]+") do
        if type(current) ~= "table" then return nil end

        -- Check for array index: name[index]
        local name, idx = segment:match("^(.-)%[(%d+)%]$")
        if name and idx then
            if name ~= "" then
                current = current[name]
                if type(current) ~= "table" then return nil end
            end
            current = current[tonumber(idx)]
        else
            -- Try string key first, then numeric
            local val = current[segment]
            if val == nil then
                local num = tonumber(segment)
                if num then val = current[num] end
            end
            current = val
        end
    end
    return current
end

-- ============================================================================
-- Filters
-- ============================================================================

local filters = {}

--- Format a number as currency with 2 decimal places and comma separators
-- e.g. 12345.6 -> "12,345.60"
function filters.currency(value)
    local num = tonumber(value)
    if not num then return tostring(value or "") end

    local negative = num < 0
    num = math.abs(num)

    -- Format to 2 decimal places
    local formatted = string.format("%.2f", num)
    local int_part, dec_part = formatted:match("^(%d+)(%.%d+)$")

    -- Add comma separators to integer part
    local with_commas = ""
    local len = #int_part
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then
            with_commas = with_commas .. ","
        end
        with_commas = with_commas .. int_part:sub(i, i)
    end

    local result = with_commas .. dec_part
    if negative then result = "-" .. result end
    return result
end

--- Format a date string as "DD MMM YYYY"
-- Accepts ISO dates (YYYY-MM-DD) or timestamps
function filters.date_format(value)
    if value == nil then return "" end
    local str = tostring(value)

    local months = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    }

    -- Try ISO format YYYY-MM-DD
    local y, m, d = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if y and m and d then
        local mi = tonumber(m)
        if mi >= 1 and mi <= 12 then
            return string.format("%s %s %s", d, months[mi], y)
        end
    end

    return str
end

--- Convert to uppercase
function filters.uppercase(value)
    return tostring(value or ""):upper()
end

--- Convert to lowercase
function filters.lowercase(value)
    return tostring(value or ""):lower()
end

--- Format number with comma separators (no decimals)
-- e.g. 1234567 -> "1,234,567"
function filters.number_format(value)
    local num = tonumber(value)
    if not num then return tostring(value or "") end

    local negative = num < 0
    num = math.abs(num)

    local formatted = string.format("%d", math.floor(num))
    local len = #formatted
    local result = ""
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then
            result = result .. ","
        end
        result = result .. formatted:sub(i, i)
    end

    -- Append decimals if present
    local dec = string.format("%.10g", num):match("%.(%d+)$")
    if dec then
        result = result .. "." .. dec
    end

    if negative then result = "-" .. result end
    return result
end

--- Raw filter - marks output as not needing escaping (identity function)
function filters.raw(value)
    return tostring(value or "")
end

-- ============================================================================
-- Tokenizer
-- ============================================================================

-- Token types
local TOKEN_TEXT = "text"
local TOKEN_VARIABLE = "variable"
local TOKEN_FOR_START = "for_start"
local TOKEN_FOR_END = "for_end"
local TOKEN_IF_START = "if_start"
local TOKEN_ELSE = "else"
local TOKEN_IF_END = "if_end"

--- Tokenize a template string into a list of tokens
-- @param template string The template source
-- @return table List of token tables
local function tokenize(template)
    local tokens = {}
    local pos = 1
    local len = #template

    while pos <= len do
        -- Look for the next tag
        local var_start = template:find("{{", pos, true)
        local tag_start = template:find("{%", pos, true)

        -- Find the nearest opening tag
        local nearest = nil
        local nearest_type = nil

        if var_start and (not tag_start or var_start < tag_start) then
            nearest = var_start
            nearest_type = "var"
        elseif tag_start then
            nearest = tag_start
            nearest_type = "tag"
        end

        if not nearest then
            -- No more tags; rest is plain text
            if pos <= len then
                tokens[#tokens + 1] = { type = TOKEN_TEXT, value = template:sub(pos) }
            end
            break
        end

        -- Emit text before the tag
        if nearest > pos then
            tokens[#tokens + 1] = { type = TOKEN_TEXT, value = template:sub(pos, nearest - 1) }
        end

        if nearest_type == "var" then
            -- Variable tag: {{ ... }}
            local close = template:find("}}", nearest + 2, true)
            if not close then
                -- Unclosed variable tag, treat rest as text
                tokens[#tokens + 1] = { type = TOKEN_TEXT, value = template:sub(nearest) }
                break
            end
            local content = trim(template:sub(nearest + 2, close - 1))
            tokens[#tokens + 1] = { type = TOKEN_VARIABLE, value = content }
            pos = close + 2
        else
            -- Control tag: {% ... %}
            local close = template:find("%}", nearest + 2, true)
            if not close then
                tokens[#tokens + 1] = { type = TOKEN_TEXT, value = template:sub(nearest) }
                break
            end
            local content = trim(template:sub(nearest + 2, close - 1))
            pos = close + 2

            -- Determine tag type
            local for_var, for_collection = content:match("^for%s+(%S+)%s+in%s+(.+)$")
            if for_var then
                tokens[#tokens + 1] = {
                    type = TOKEN_FOR_START,
                    variable = trim(for_var),
                    collection = trim(for_collection),
                }
            elseif content:match("^endfor$") then
                tokens[#tokens + 1] = { type = TOKEN_FOR_END }
            elseif content:match("^if%s+") then
                local condition = content:match("^if%s+(.+)$")
                tokens[#tokens + 1] = {
                    type = TOKEN_IF_START,
                    condition = trim(condition),
                }
            elseif content:match("^else$") then
                tokens[#tokens + 1] = { type = TOKEN_ELSE }
            elseif content:match("^endif$") then
                tokens[#tokens + 1] = { type = TOKEN_IF_END }
            else
                -- Unknown tag, output as text
                tokens[#tokens + 1] = { type = TOKEN_TEXT, value = "{%" .. content .. "%}" }
            end
        end
    end

    return tokens
end

-- ============================================================================
-- AST Builder
-- ============================================================================

--- Build a simple AST from a flat token list
-- Returns a tree of nodes: text, variable, for_block, if_block
-- @param tokens table Flat list of tokens
-- @return table AST node list
-- @return string|nil Error message
local function build_ast(tokens)
    local function parse_block(toks, idx)
        local nodes = {}
        while idx <= #toks do
            local tok = toks[idx]

            if tok.type == TOKEN_TEXT then
                nodes[#nodes + 1] = { type = "text", value = tok.value }
                idx = idx + 1

            elseif tok.type == TOKEN_VARIABLE then
                nodes[#nodes + 1] = { type = "variable", value = tok.value }
                idx = idx + 1

            elseif tok.type == TOKEN_FOR_START then
                local body, err
                body, idx, err = parse_block(toks, idx + 1)
                if err then return nil, idx, err end
                if not toks[idx] or toks[idx].type ~= TOKEN_FOR_END then
                    return nil, idx, "Unclosed {% for %} block: missing {% endfor %}"
                end
                nodes[#nodes + 1] = {
                    type = "for_block",
                    variable = tok.variable,
                    collection = tok.collection,
                    body = body,
                }
                idx = idx + 1

            elseif tok.type == TOKEN_IF_START then
                local if_body, err
                if_body, idx, err = parse_block(toks, idx + 1)
                if err then return nil, idx, err end
                local else_body = nil
                if toks[idx] and toks[idx].type == TOKEN_ELSE then
                    else_body, idx, err = parse_block(toks, idx + 1)
                    if err then return nil, idx, err end
                end
                if not toks[idx] or toks[idx].type ~= TOKEN_IF_END then
                    return nil, idx, "Unclosed {% if %} block: missing {% endif %}"
                end
                nodes[#nodes + 1] = {
                    type = "if_block",
                    condition = tok.condition,
                    if_body = if_body,
                    else_body = else_body,
                }
                idx = idx + 1

            elseif tok.type == TOKEN_FOR_END or tok.type == TOKEN_IF_END or tok.type == TOKEN_ELSE then
                -- End of current block scope
                return nodes, idx, nil

            else
                idx = idx + 1
            end
        end
        return nodes, idx, nil
    end

    local nodes, _, err = parse_block(tokens, 1)
    if err then return nil, err end
    return nodes, nil
end

-- ============================================================================
-- Evaluator
-- ============================================================================

--- Evaluate a condition string against data context
-- Supports: truthy checks, comparisons (==, !=, >, <, >=, <=)
-- @param condition string
-- @param data table
-- @return boolean
local function evaluate_condition(condition, data)
    -- Check for comparison operators
    local lhs, op, rhs

    -- Try two-char operators first
    lhs, op, rhs = condition:match("^(.-)%s*(==)%s*(.+)$")
    if not op then lhs, op, rhs = condition:match("^(.-)%s*(!=)%s*(.+)$") end
    if not op then lhs, op, rhs = condition:match("^(.-)%s*(>=)%s*(.+)$") end
    if not op then lhs, op, rhs = condition:match("^(.-)%s*(<=)%s*(.+)$") end
    if not op then lhs, op, rhs = condition:match("^(.-)%s*(>)%s*(.+)$") end
    if not op then lhs, op, rhs = condition:match("^(.-)%s*(<)%s*(.+)$") end

    if op then
        lhs = trim(lhs)
        rhs = trim(rhs)

        -- Resolve values
        local lval, rval

        -- Check if RHS is a string literal
        local str_lit = rhs:match('^"(.*)"$') or rhs:match("^'(.*)'$")
        if str_lit then
            rval = str_lit
        elseif rhs == "true" then
            rval = true
        elseif rhs == "false" then
            rval = false
        elseif rhs == "nil" or rhs == "null" then
            rval = nil
        elseif tonumber(rhs) then
            rval = tonumber(rhs)
        else
            rval = resolve(data, rhs)
        end

        lval = resolve(data, lhs)

        -- Numeric comparison if both are numbers
        local lnum = tonumber(lval)
        local rnum = tonumber(rval)

        if op == "==" then return lval == rval
        elseif op == "!=" then return lval ~= rval
        elseif op == ">" then return (lnum and rnum) and lnum > rnum or false
        elseif op == "<" then return (lnum and rnum) and lnum < rnum or false
        elseif op == ">=" then return (lnum and rnum) and lnum >= rnum or false
        elseif op == "<=" then return (lnum and rnum) and lnum <= rnum or false
        end
    end

    -- Simple truthiness check
    local val = resolve(data, condition)
    if val == nil or val == false or val == "" or val == 0 then
        return false
    end
    return true
end

--- Parse a variable expression for filters: "variable | filter1 | filter2"
-- @param expr string
-- @return string variable_path
-- @return table list of filter names
local function parse_variable_expr(expr)
    local parts = {}
    for part in expr:gmatch("[^|]+") do
        parts[#parts + 1] = trim(part)
    end
    local var_path = parts[1] or ""
    local filter_list = {}
    for i = 2, #parts do
        filter_list[#filter_list + 1] = parts[i]
    end
    return var_path, filter_list
end

--- Evaluate the AST against data context
-- @param nodes table AST nodes
-- @param data table Data context
-- @param options table Render options
-- @return string Rendered output
-- @return string|nil Error
local function evaluate(nodes, data, options)
    local output = {}
    local escape = options.escape_html ~= false  -- default true
    local total_iterations = { count = 0 }

    local function eval_nodes(node_list, ctx)
        for _, node in ipairs(node_list) do
            if node.type == "text" then
                output[#output + 1] = node.value

            elseif node.type == "variable" then
                local var_path, filter_list = parse_variable_expr(node.value)
                local value = resolve(ctx, var_path)

                -- Check for string literal
                if value == nil then
                    local str_lit = var_path:match('^"(.*)"$') or var_path:match("^'(.*)'$")
                    if str_lit then value = str_lit end
                end

                if value == nil then
                    value = ""
                end

                value = tostring(value)

                -- Apply filters
                local is_raw = false
                for _, fname in ipairs(filter_list) do
                    if fname == "raw" then
                        is_raw = true
                    end
                    local fn = filters[fname]
                    if fn then
                        value = fn(value)
                    end
                end

                -- HTML escape unless raw filter applied or escape disabled
                if escape and not is_raw then
                    value = html_escape(value)
                end

                output[#output + 1] = value

            elseif node.type == "for_block" then
                local collection = resolve(ctx, node.collection)
                if type(collection) == "table" then
                    for i, item in ipairs(collection) do
                        total_iterations.count = total_iterations.count + 1
                        if total_iterations.count > MAX_LOOP_ITERATIONS then
                            output[#output + 1] = "<!-- loop iteration limit reached -->"
                            return
                        end
                        -- Create child context with loop variable and forloop metadata
                        local child = {}
                        for k, v in pairs(ctx) do child[k] = v end
                        child[node.variable] = item
                        child.forloop = {
                            index = i,
                            index0 = i - 1,
                            first = (i == 1),
                            last = (i == #collection),
                            length = #collection,
                        }
                        eval_nodes(node.body, child)
                    end
                end

            elseif node.type == "if_block" then
                local result = evaluate_condition(node.condition, ctx)
                if result then
                    eval_nodes(node.if_body, ctx)
                elseif node.else_body then
                    eval_nodes(node.else_body, ctx)
                end
            end
        end
    end

    eval_nodes(nodes, data)
    return table.concat(output), nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Sanitize rendered HTML output by stripping dangerous tags
-- @param html string
-- @return string Sanitized HTML
function TemplateRenderer.sanitizeOutput(html)
    if not html then return "" end
    -- Remove <script>...</script> (case-insensitive, including attributes)
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-<%s*/%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
    -- Remove unclosed/self-closing <script> tags
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>", "")

    -- Remove <iframe>...</iframe>
    html = html:gsub("<%s*[Ii][Ff][Rr][Aa][Mm][Ee][^>]*>.-<%s*/%s*[Ii][Ff][Rr][Aa][Mm][Ee]%s*>", "")
    html = html:gsub("<%s*[Ii][Ff][Rr][Aa][Mm][Ee][^>]*>", "")

    -- Remove <object>...</object>
    html = html:gsub("<%s*[Oo][Bb][Jj][Ee][Cc][Tt][^>]*>.-<%s*/%s*[Oo][Bb][Jj][Ee][Cc][Tt]%s*>", "")
    html = html:gsub("<%s*[Oo][Bb][Jj][Ee][Cc][Tt][^>]*>", "")

    -- Remove <embed>...</embed> and self-closing
    html = html:gsub("<%s*[Ee][Mm][Bb][Ee][Dd][^>]*>.-<%s*/%s*[Ee][Mm][Bb][Ee][Dd]%s*>", "")
    html = html:gsub("<%s*[Ee][Mm][Bb][Ee][Dd][^>]*/?>", "")

    return html
end

--- Render a template string with data context
-- @param template_html string The HTML template with {{variables}} and {% control %}
-- @param data table The data context (company, invoice, client, theme, etc.)
-- @param options table Optional: {css = "...", escape_html = true}
-- @return string Rendered HTML
function TemplateRenderer.render(template_html, data, options)
    if not template_html then return "" end
    options = options or {}
    data = data or {}

    -- Enforce template size limit
    if #template_html > MAX_TEMPLATE_SIZE then
        return "<!-- template exceeds maximum size of 500KB -->"
    end

    -- Tokenize
    local tokens = tokenize(template_html)

    -- Build AST
    local ast, err = build_ast(tokens)
    if err then
        return "<!-- template error: " .. html_escape(err) .. " -->"
    end

    -- Evaluate
    local rendered
    rendered, err = evaluate(ast, data, options)
    if err then
        return "<!-- render error: " .. html_escape(err) .. " -->"
    end

    -- Inject CSS if provided
    if options.css and options.css ~= "" then
        local style_tag = "<style>" .. options.css .. "</style>"
        -- Insert before </head> if present, otherwise prepend
        if rendered:find("</head>") then
            rendered = rendered:gsub("</head>", style_tag .. "</head>", 1)
        else
            rendered = style_tag .. rendered
        end
    end

    -- Sanitize output to strip dangerous tags
    rendered = TemplateRenderer.sanitizeOutput(rendered)

    return rendered
end

--- Validate a template for syntax errors
-- @param template_html string
-- @return boolean valid
-- @return string|nil error_message
function TemplateRenderer.validate(template_html)
    if not template_html then
        return false, "Template is nil"
    end
    if #template_html > MAX_TEMPLATE_SIZE then
        return false, "Template exceeds maximum size of 500KB"
    end

    local tokens = tokenize(template_html)
    local _, err = build_ast(tokens)
    if err then
        return false, err
    end

    return true, nil
end

--- Get list of variables used in a template
-- @param template_html string
-- @return table List of variable paths found
function TemplateRenderer.extractVariables(template_html)
    if not template_html then return {} end

    local variables = {}
    local seen = {}

    -- Extract {{variable}} references
    for expr in template_html:gmatch("{{(.-)}}") do
        local var_path = parse_variable_expr(trim(expr))
        if var_path ~= "" and not seen[var_path] then
            seen[var_path] = true
            variables[#variables + 1] = var_path
        end
    end

    -- Extract collection references from {% for x in collection %}
    for collection in template_html:gmatch("{%%%s*for%s+%S+%s+in%s+(.-)%s*%%}") do
        local col = trim(collection)
        if col ~= "" and not seen[col] then
            seen[col] = true
            variables[#variables + 1] = col
        end
    end

    -- Extract condition references from {% if condition %}
    for condition in template_html:gmatch("{%%%s*if%s+(.-)%s*%%}") do
        local cond = trim(condition)
        -- Strip comparison parts to get variable names
        local lhs = cond:match("^(.-)%s*[=!<>]") or cond
        lhs = trim(lhs)
        if lhs ~= "" and not seen[lhs] then
            seen[lhs] = true
            variables[#variables + 1] = lhs
        end
    end

    return variables
end

return TemplateRenderer
