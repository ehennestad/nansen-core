function info = analyzeSessionMethod(name, text)
%analyzeSessionMethod What a NANSEN dev session method's file says about it, read from its text without running it
%
%   info = nansen.legacy.analyzeSessionMethod(name, text) for the file
%   name.m gives kind ("function" or "class"), title, description,
%   batchMode, queueable and options (a JSON Schema struct). The rules are
%   those of Python's nansen.legacymethods.analyze, and
%   conformance/api/legacy-methods holds the two to the same result:
%
%   - a function is a session method when it calls dev's
%     nansen.session.SessionMethod.setAttributes; its ATTRIBUTES (and the
%     flags given to setAttributes) say batch and unqueueable;
%   - a class is one when it subclasses nansen.session.SessionMethod (and
%     no other class of dev's nansen); its constant BatchMode, IsQueueable
%     and MethodName say the rest;
%   - the options are the fields of the defaults (getDefaultParameters of a
%     function, the static getDefaultOptions of a class) set to plain
%     values: true/false, numbers, text, rows of numbers, cells of text.
%     a.b sets an option of an object option a. dev's <name>_ field that
%     lists the choices of a text option becomes its enum. Other defaults
%     are left to dev's code at run time.
%
%   unsupported-file when the file is not a dev session method.
    arguments
        name (1,1) string
        text
    end
    text = string(text);
    text = replace(replace(text, sprintf("\r\n"), newline), sprintf("\r"), newline);
    lines = reshape(split(text, newline), 1, []);
    first = 0;
    for i = 1:numel(lines)
        stripped = strtrim(lines(i));
        if stripped ~= "" && ~startsWith(stripped, "%")
            first = i;
            break
        end
    end
    if first == 0
        nansen.internal.throwError("unsupported-file", "%s.m holds no code", name)
    end
    declaration = strtrim(codeOf(lines(first)));
    if ~isempty(regexp(declaration, '^classdef(?!\w)', 'once'))
        kind = "class";
    elseif ~isempty(regexp(declaration, '^function(?!\w)', 'once'))
        kind = "function";
    else
        nansen.internal.throwError("unsupported-file", "%s.m is a script, not a function or class", name)
    end
    info = struct("kind", kind, "title", "", "description", describe(lines, first, name), ...
        "batchMode", "serial", "queueable", true, "options", struct());
    if kind == "function"
        [assignments, info] = functionOptions(name, lines, first, info);
    else
        [assignments, info] = classOptions(name, declaration, lines, info);
    end
    info.options = struct("type", 'object', "properties", propertiesOf(assignments));
    if info.title == ""
        info.title = labelOf(name);
    end
end

function description = describe(lines, first, name)
    % The first line of the help text (the comments after the declaration), less a leading word that is the name
    description = "";
    if first + 1 > numel(lines) || ~startsWith(strtrim(lines(first + 1)), "%")
        return
    end
    text = strtrim(regexprep(char(strtrim(lines(first + 1))), '^%+\s*', ''));
    tokens = regexp(text, '^(\S+)\s*(.*)$', 'tokens', 'once');
    if ~isempty(tokens) && strcmp(lower(tokens{1}), lower(char(name)))
        text = strtrim(tokens{2});
    end
    description = string(text);
end

function [assignments, info] = functionOptions(name, lines, first, info)
    % A function method's attributes (its ATTRIBUTES and setAttributes flags) and the assignments of its defaults
    codes = strings(1, numel(lines));
    for i = 1:numel(lines)
        codes(i) = string(codeOf(lines(i)));
    end
    call = find(contains(codes, "SessionMethod.setAttributes"), 1);
    if isempty(call)
        nansen.internal.throwError("unsupported-file", "%s.m does not call nansen.session.SessionMethod.setAttributes, " + ...
            "so it is not a dev session method", name)
    end
    words = strings(1, 0);
    attributes = regexp(char(strjoin(codes, newline)), 'ATTRIBUTES\s*=\s*\{([^}]*)\}', 'tokens', 'once');
    if ~isempty(attributes)
        words = [words, quotedIn(attributes{1})];
    end
    arguments_ = regexp(char(codes(call)), 'setAttributes\(([^)]*)\)', 'tokens', 'once');
    variable = "";
    if ~isempty(arguments_)
        words = [words, quotedIn(arguments_{1})];
        start = regexp(arguments_{1}, '^\s*([A-Za-z]\w*)\s*(?:,|$)', 'tokens', 'once');
        if ~isempty(start)
            variable = string(start{1});
        end
    end
    lowered = lower(words);
    if any(lowered == "batch")
        info.batchMode = "batch";
    end
    if any(lowered == "unqueueable")
        info.queueable = false;
    end
    index = find(lowered == "methodname", 1);
    if ~isempty(index) && index < numel(words)
        info.title = strtrim(words(index + 1));
    end
    assignments = {};
    if variable == ""
        return
    end
    for i = first + 1:call - 1   % params = getDefaultParameters(): that local function's fields
        source = regexp(char(codes(i)), ['^\s*', char(variable), '\s*=\s*([A-Za-z]\w*)\s*(?:\(\s*\))?\s*;?\s*$'], 'tokens', 'once');
        if ~isempty(source)
            assignments = [assignments, bodyAssignments(lines, source{1})]; %#ok<AGROW>
        end
    end
    assignments = [assignments, assignmentsOf(lines(first + 1:call - 1), variable)];   % and its fields set in the function itself
end

function [assignments, info] = classOptions(name, declaration, lines, info)
    % A class method's attributes (its constant properties) and the assignments of getDefaultOptions
    sessionMethod = "nansen.session.SessionMethod";
    % the superclasses: after the < of the declaration (outside its attributes in brackets), split at &
    declaration = char(declaration);
    attributes = regexp(declaration, '^classdef\s*\([^)]*\)', 'end', 'once');
    if isempty(attributes)
        attributes = 0;
    end
    at = find(declaration == '<' & (1:numel(declaration)) > attributes, 1);
    supers = strings(1, 0);
    if ~isempty(at)
        supers = reshape(strtrim(split(string(declaration(at + 1:end)), "&")), 1, []);
    end
    if ~ismember(sessionMethod, supers)
        nansen.internal.throwError("unsupported-file", "%s.m is a class that does not subclass %s, " + ...
            "so it is not a dev session method", name, sessionMethod)
    end
    others = supers(startsWith(supers, "nansen.") & supers ~= sessionMethod);
    if ~isempty(others)
        nansen.internal.throwError("unsupported-file", "%s.m also subclasses %s, which nansen-core does not have", ...
            name, strjoin(others, ", "))
    end
    for i = 1:numel(lines)
        code = codeOf(lines(i));
        batch = regexp(code, '^\s*BatchMode\s*=\s*[''"](\w+)[''"]', 'tokens', 'once');
        if ~isempty(batch) && strcmpi(batch{1}, 'batch')
            info.batchMode = "batch";
        end
        queueable = regexp(code, '^\s*IsQueueable\s*=\s*(true|false)(?!\w)', 'tokens', 'once');
        if ~isempty(queueable)
            info.queueable = strcmp(queueable{1}, 'true');
        end
        title = regexp(code, '^\s*MethodName\s*=\s*''([^'']*)''', 'tokens', 'once');
        if isempty(title)
            title = regexp(code, '^\s*MethodName\s*=\s*"([^"]*)"', 'tokens', 'once');
        end
        if ~isempty(title) && info.title == ""
            info.title = strtrim(string(title{1}));
        end
    end
    assignments = bodyAssignments(lines, "getDefaultOptions");
end

function found = bodyAssignments(lines, functionName)
    % The field assignments of the output of a function (local, or a static method) of the file
    found = {};
    for index = 1:numel(lines)
        tokens = regexp(codeOf(lines(index)), ['^\s*function\s+([A-Za-z]\w*)\s*=\s*', char(functionName), '(?!\w)'], 'tokens', 'once');
        if isempty(tokens)
            continue
        end
        indent = indentOf(lines(index));
        body = strings(1, 0);
        for k = index + 1:numel(lines)
            code = strtrim(codeOf(lines(k)));
            if ~isempty(regexp(code, '^function(?!\w)', 'once'))
                break
            end
            if ~isempty(regexp(code, '^end(?!\w)', 'once')) && indentOf(lines(k)) <= indent
                break
            end
            body(end + 1) = lines(k); %#ok<AGROW>
        end
        found = assignmentsOf(body, string(tokens{1}));
        return
    end
end

function count = indentOf(line)
    count = numel(regexp(char(line), '^\s*', 'match', 'once'));
end

function found = assignmentsOf(lines, variable)
    % {path, value text, comment} of each `variable.a.b = value` line
    found = {};
    for i = 1:numel(lines)
        [code, comment] = codeOf(lines(i));
        tokens = regexp(code, ['^\s*', char(variable), '((?:\.[A-Za-z]\w*)+)\s*=(?!=)\s*(.*)$'], 'tokens', 'once');
        if ~isempty(tokens)
            path = reshape(split(string(tokens{1}(2:end)), "."), 1, []);
            found{end + 1} = struct("path", path, "value", tokens{2}, "comment", comment); %#ok<AGROW>
        end
    end
end

function [code, comment] = codeOf(line)
    % A line's code and its comment (the text after a % outside quotes)
    line = char(line);
    code = line;
    comment = '';
    quote = '';
    for k = 1:numel(line)
        c = line(k);
        if ~isempty(quote)
            if c == quote
                quote = '';
            end
        elseif c == '"' || (c == '''' && (k == 1 || isempty(regexp(line(k - 1), '[\w)\]}.]', 'once'))))
            quote = c;   % a ' after a name, a closing bracket or a dot is a transpose
        elseif c == '%'
            code = line(1:k - 1);
            comment = strtrim(regexprep(line(k:end), '^%*\s*', ''));
            return
        end
    end
end

function pattern = quotedPattern()
    pattern = ['''(?:[^'']|'''')*''', '|', '"(?:[^"]|"")*"'];
end

function values = quotedIn(text)
    found = regexp(char(text), quotedPattern(), 'match');
    values = strings(1, numel(found));
    for i = 1:numel(found)
        values(i) = string(unquote(found{i}));
    end
end

function text = unquote(text)
    quote = text(1);
    text = strrep(text(2:end - 1), [quote, quote], quote);
end

function tf = isFull(text, pattern)
    tf = ~isempty(regexp(text, ['^(?:', pattern, ')$'], 'once'));
end

function [ok, value] = literalOf(text)
    % (true, value) for a plain MATLAB value: true/false, a number, text, a row of numbers or a cell of text
    number = '[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?';
    code = strtrim(char(text));
    while ~isempty(code) && (code(end) == ';' || code(end) == ',')
        code = strtrim(code(1:end - 1));
    end
    ok = true;
    value = [];
    if strcmp(code, 'true') || strcmp(code, 'false')
        value = strcmp(code, 'true');
        return
    end
    if isFull(code, number)
        value = str2double(code);
        return
    end
    if isFull(code, quotedPattern())
        value = unquote(code);
        return
    end
    if numel(code) >= 2 && code(1) == '[' && code(end) == ']'
        items = regexp(strtrim(code(2:end - 1)), '[\s,]+', 'split');
        items = items(~cellfun(@isempty, items));
        if ~isempty(items) && all(cellfun(@(item) isFull(item, number), items))
            value = cellfun(@str2double, items);
            return
        end
        ok = false;
        return
    end
    if numel(code) >= 2 && code(1) == '{' && code(end) == '}'
        inner = code(2:end - 1);
        rest = regexprep(inner, quotedPattern(), '');
        if all(ismember(rest, [' ', ',', sprintf('\t')]))
            found = regexp(inner, quotedPattern(), 'match');
            value = cellfun(@unquote, found, UniformOutput=false);
            value = reshape(value, 1, []);
            return
        end
    end
    ok = false;
end

function schema = schemaOf(value)
    if islogical(value)
        schema = struct("type", 'boolean', "default", value);
    elseif ischar(value)
        schema = struct("type", 'string', "default", value);
    elseif isnumeric(value) && isscalar(value)
        schema = struct("type", 'number', "default", value);
    elseif isnumeric(value)
        schema = struct("type", 'array', "items", struct("type", 'number'), "default", value);
    else
        schema = struct("type", 'array', "items", struct("type", 'string'), "default", {value});
    end
end

function properties = propertiesOf(assignments)
    % The options' properties: one per field set to a plain value, nested for a.b; a later assignment wins
    properties = struct();
    choices = {};
    for i = 1:numel(assignments)
        assignment = assignments{i};
        [ok, value] = literalOf(assignment.value);
        path = assignment.path;
        last = char(path(end));
        if endsWith(last, "_")   % dev's config field: the choices of the field of that name
            if ok && iscell(value)
                choices{end + 1} = struct("path", [path(1:end - 1), string(last(1:end - 1))], "values", {value}); %#ok<AGROW>
            end
            continue
        end
        schema = [];
        if ok
            schema = schemaOf(value);
            if ~isempty(assignment.comment)
                schema.description = assignment.comment;
            end
        end
        properties = place(properties, path, schema, ok);
    end
    for i = 1:numel(choices)
        properties = withEnum(properties, choices{i}.path, choices{i}.values);
    end
end

function properties = place(properties, path, schema, ok)
    % Set (ok) or remove (the default is not a plain value: dev's own is used) the property at path
    name = char(path(1));
    if isscalar(path)
        if ok
            properties.(name) = schema;
        elseif isfield(properties, name)
            properties = rmfield(properties, name);
        end
        return
    end
    if isfield(properties, name) && isObject(properties.(name))
        node = properties.(name);
    elseif ok
        node = struct("type", 'object', "properties", struct());
    else
        return
    end
    node.properties = place(node.properties, path(2:end), schema, ok);
    properties.(name) = node;
end

function tf = isObject(node)
    tf = isstruct(node) && isfield(node, "type") && strcmp(node.type, 'object');
end

function properties = withEnum(properties, path, values)
    % A text option whose default is among dev's choices of it gets them as its enum
    name = char(path(1));
    if ~isfield(properties, name)
        return
    end
    node = properties.(name);
    if isscalar(path)
        if isstruct(node) && strcmp(node.type, 'string') && ismember(string(node.default), string(values))
            node.enum = values;
            properties.(name) = node;
        end
        return
    end
    if isObject(node)
        node.properties = withEnum(node.properties, path(2:end), values);
        properties.(name) = node;
    end
end

function text = labelOf(name)
    % dev's varname2label: words of a camelCase name, the first letter upper case
    text = regexprep(char(name), '([a-z0-9])([A-Z])', '$1 $2');
    text = strtrim(regexprep(strrep(text, '_', ' '), '\s+', ' '));
    if ~isempty(text)
        text(1) = upper(text(1));
    end
    text = string(text);
end
