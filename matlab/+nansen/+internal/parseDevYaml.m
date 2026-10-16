function result = parseDevYaml(source)
%parseDevYaml The value of the first YAML document in the text of one of NANSEN dev's metadata files
%
%   value = nansen.internal.parseDevYaml(text) reads the simple YAML dev's
%   YAML toolbox (SnakeYAML) writes for an adapter's metadata (setMetadata)
%   and an image stack's (StackMetadata), by the rules of Python's
%   nansen.devyaml.parse; the cases in conformance/yaml hold the two to the
%   same result. A mapping is a struct (its keys that are not MATLAB names,
%   or are keywords, left out with their values), a sequence a 1 x n cell,
%   text a char row, null [], true and false logicals and numbers doubles.
%   Anchors, aliases, tags and complex keys are not read: invalid-data, as
%   is text that is not YAML.
    % (the parent's variables, which its nested functions share: source, lines, row, col and result)
    source = char(source);
    source = strrep(strrep(source, sprintf('\r\n'), newline), sprintf('\r'), newline);
    if ~isempty(source) && source(1) == char(65279)
        source = source(2:end);
    end
    lines = regexp(source, '\n', 'split');
    row = 0;   % the line read last (from 1); the rest of it is done once a node is read
    col = 0;   % how many of its characters are read
    result = parseDocument();

    % -- lines ---------------------------------------------------------------------------------

    function r = rest()
        if row >= 1 && row <= numel(lines)
            line = lines{row};
            r = line(col + 1:end);
        else
            r = '';
        end
    end

    function tf = restBlank()
        r = lstripWs(rest());
        tf = isempty(r) || r(1) == '#';
    end

    function n = indentOf(r)
        % The indentation of line r, or -1 when it is blank or a comment
        line = lines{r};
        n = leadingSpaces(line);
        content = lstripWs(line(n + 1:end));
        if isempty(content) || content(1) == '#'
            n = -1;
            return
        end
        if isequal(at(line, n), char(9))
            fail("a tab in the indentation", r);
        end
    end

    function n = nextContent()
        % Go to the next line with content and return its indentation (-1 at the end of the document)
        r = row + 1;
        while r <= numel(lines)
            n = indentOf(r);
            if n >= 0
                if n == 0 && isMarker(lines{r})
                    break
                end
                row = r;
                col = n;
                return
            end
            r = r + 1;
        end
        row = numel(lines) + 1;
        col = 0;
        n = -1;
    end

    % -- the document --------------------------------------------------------------------------

    function value = parseDocument()
        r = 1;
        while r <= numel(lines) && (indentOf(r) < 0 || startsWith(lines{r}, '%'))
            r = r + 1;
        end
        if r <= numel(lines) && startsWith(lines{r}, '---') && isSpaceOrEnd(at(lines{r}, 3))
            row = r;
            col = 3;
            if ~restBlank()   % --- {a: 1}
                col = col + numel(rest()) - numel(lstripWs(rest()));
                value = nodeHere(-1);
                endOfValue();
                return
            end
        else
            row = r - 1;
        end
        value = blockNode(-1, false);
        if nextContent() >= 0
            fail("unexpected '" + string(stripWs(rest())) + "'", row);
        end
    end

    function endOfValue()
        if ~restBlank()
            fail("unexpected '" + string(stripWs(rest())) + "'", row);
        end
    end

    function value = blockNode(parent, sequenceAtParent)
        % The node on the lines after the current one, more indented than its parent ([] when there is none)
        savedRow = row;
        savedCol = col;
        n = nextContent();
        if n > parent || (sequenceAtParent && n == parent && n >= 0 && isEntry(rest()))
            value = nodeHere(parent);
            return
        end
        row = savedRow;
        col = savedCol;
        value = [];
    end

    function value = nodeHere(parent)
        % The node that starts at the current column: a block sequence, a block mapping or a value
        if isEntry(rest())
            value = blockSequence(col);
        elseif keyEnd() >= 0
            value = blockMapping(col);
        else
            value = inlineValue(parent);
        end
    end

    function out = blockMapping(n)
        out = struct();
        while true
            key = readKey();
            col = col + numel(rest()) - numel(lstripWs(rest()));
            if restBlank()
                item = blockNode(n, true);
            else
                item = inlineValue(n);
            end
            if keyOk(key)
                out.(key) = item;
            end
            savedRow = row;
            savedCol = col;
            m = nextContent();
            if m < n || m < 0
                row = savedRow;
                col = savedCol;
                return
            end
            if m > n || keyEnd() < 0
                fail("a mapping's entries must line up, as key: value", row);
            end
        end
    end

    function out = blockSequence(n)
        out = {};
        while true
            col = n + 1;
            col = col + numel(rest()) - numel(lstripWs(rest()));
            if restBlank()
                out{end + 1} = blockNode(n, false); %#ok<AGROW>
            else
                out{end + 1} = nodeHere(n); %#ok<AGROW>
            end
            savedRow = row;
            savedCol = col;
            m = nextContent();
            if m < n || m < 0 || (m == n && ~isEntry(rest()))
                row = savedRow;
                col = savedCol;
                return
            end
            if m > n
                fail("a sequence's items must line up, as - item", row);
            end
        end
    end

    function j = keyEnd()
        % Where (from 0) the ':' after a key at the current column is in the line, or -1 when none is there
        line = lines{row};
        i = col;
        j = -1;
        if i >= numel(line) || any(line(i + 1) == '[{#|>?&*!%@`') || isEntry(line(i + 1:end))
            return
        end
        if line(i + 1) == '''' || line(i + 1) == '"'
            e = quotedEnd(line, i + 1, line(i + 1));
            if e < 0
                return
            end
            k = e + 1;
            while k < numel(line) && (line(k + 1) == ' ' || line(k + 1) == char(9))
                k = k + 1;
            end
            if k < numel(line) && line(k + 1) == ':' && isSpaceOrEnd(at(line, k + 1))
                j = k;
            end
            return
        end
        k = i;
        while k < numel(line)
            if line(k + 1) == ':' && isSpaceOrEnd(at(line, k + 1))
                j = k;
                return
            end
            if line(k + 1) == '#' && k > 0 && (line(k) == ' ' || line(k) == char(9))
                return
            end
            k = k + 1;
        end
    end

    function key = readKey()
        line = lines{row};
        j = keyEnd();
        if line(col + 1) == '''' || line(col + 1) == '"'
            e = quotedEnd(line, col + 1, line(col + 1));
            key = unquote(line(col + 1), line(col + 2:e), row);
        else
            key = rstripWs(line(col + 1:j));
        end
        col = j + 1;
    end

    % -- values ------------------------------------------------------------------------------

    function value = inlineValue(parent)
        % A value that starts at the current column: a flow collection, a quoted or plain scalar, or a block
        r = rest();
        first = r(1);
        if first == '[' || first == '{'
            value = flowNode();
        elseif first == '''' || first == '"'
            value = quoted();
        elseif first == '|' || first == '>'
            value = blockScalar(parent);
            return
        elseif any(first == '&*!%@`')
            fail("anchors, aliases, tags and directives are not read: '" + string(stripWs(r)) + "'", row);
        else
            value = resolveScalar(plainBlock(parent));
            return
        end
        endOfValue();
    end

    function text = plainBlock(parent)
        % A plain scalar in a block, with the more indented lines after it that go on with it
        text = stripWs(cutComment(rest()));
        col = numel(lines{row});
        breaks = 0;
        r = row + 1;
        while r <= numel(lines)
            line = lines{r};
            content = stripWs(line);
            if isempty(content)
                breaks = breaks + 1;
                r = r + 1;
                continue
            end
            n = leadingSpaces(line);
            if n <= parent || content(1) == '#' || (n == 0 && isMarker(line))
                break
            end
            if breaks > 0
                separator = repmat(newline, 1, breaks);
            else
                separator = ' ';
            end
            text = [text, separator, stripWs(cutComment(content))]; %#ok<AGROW>
            breaks = 0;
            row = r;
            col = numel(line);
            r = r + 1;
        end
        if ~isempty(regexp(text, ':([ \t\n]|$)', 'once'))   % a key where a value goes on
            fail("a mapping's entries must line up, as key: value ('" + string(text) + "')", row);
        end
    end

    function text = quoted()
        % A quoted scalar from the current column, over as many lines as it takes
        r0 = rest();
        quote = r0(1);
        startRow = row;
        parts = {};
        r = row;
        i = col + 1;
        while true
            if r > numel(lines)
                fail("a quoted scalar is not closed", startRow);
            end
            line = lines{r};
            e = quotedEnd(line, i, quote);
            if e >= 0
                parts{end + 1} = line(i + 1:e); %#ok<AGROW>
                row = r;
                col = e + 1;
                break
            end
            parts{end + 1} = line(i + 1:end); %#ok<AGROW>
            r = r + 1;
            i = 0;
        end
        text = unquote(quote, fold(parts, quote == '"'), startRow);
    end

    function text = blockScalar(parent)
        % A literal (|) or folded (>) block scalar, with its chomping indicator (- or +)
        header = stripWs(cutComment(rest()));
        style = header(1);
        chomp = '';
        for c = header(2:end)
            if (c == '+' || c == '-') && isempty(chomp)
                chomp = c;
            elseif ~any(c == '123456789')
                fail("a block scalar's header '" + string(header) + "'", row);
            end
        end
        col = numel(lines{row});
        items = {};
        indent = -1;
        r = row + 1;
        while r <= numel(lines)
            line = lines{r};
            if all(line == ' ')
                items{end + 1} = ''; %#ok<AGROW>
                r = r + 1;
                continue
            end
            n = leadingSpaces(line);
            if indent < 0
                if n <= parent
                    break
                end
                indent = n;
            end
            if n < indent
                break
            end
            items{end + 1} = line(indent + 1:end); %#ok<AGROW>
            row = r;
            col = numel(line);
            r = r + 1;
        end
        trailing = trailingEmpty(items);
        content = items(1:numel(items) - trailing);
        if isempty(content)
            text = '';
        elseif style == '|'
            text = strjoin(content, newline);
        else
            text = content{1};
            empties = 0;
            for k = 2:numel(content)
                if isempty(content{k})
                    empties = empties + 1;
                elseif empties > 0
                    text = [text, repmat(newline, 1, empties), content{k}]; %#ok<AGROW>
                    empties = 0;
                else
                    text = [text, ' ', content{k}]; %#ok<AGROW>
                end
            end
        end
        if isempty(content)
            if isequal(chomp, '+')
                text = repmat(newline, 1, trailing);
            end
        elseif isequal(chomp, '+')
            text = [text, repmat(newline, 1, 1 + trailing)];
        elseif ~isequal(chomp, '-')
            text = [text, newline];
        end
    end

    % -- flow collections ----------------------------------------------------------------------

    function flowSkip()
        % Past spaces, line breaks and comments inside a flow collection
        while true
            line = lines{row};
            while col < numel(line) && (line(col + 1) == ' ' || line(col + 1) == char(9))
                col = col + 1;
            end
            if col < numel(line) && ~(line(col + 1) == '#' && (col == 0 || line(col) == ' ' || line(col) == char(9)))
                return
            end
            row = row + 1;
            col = 0;
            if row > numel(lines)
                fail("a flow collection is not closed", row - 1);
            end
        end
    end

    function c = peek()
        c = at(lines{row}, col);
    end

    function value = flowNode()
        flowSkip();
        c = peek();
        if c == '['
            col = col + 1;
            value = {};
            while true
                flowSkip();
                if isequal(peek(), ']')
                    col = col + 1;
                    return
                end
                value{end + 1} = flowNode(); %#ok<AGROW>
                flowSkip();
                c = peek();
                col = col + 1;
                if isequal(c, ']')
                    return
                end
                if ~isequal(c, ',')
                    fail("expected , or ] in a flow sequence, not '" + string(c) + "'", row);
                end
            end
        end
        if c == '{'
            col = col + 1;
            value = struct();
            while true
                flowSkip();
                if isequal(peek(), '}')
                    col = col + 1;
                    return
                end
                c = peek();
                if c == '''' || c == '"'
                    key = quoted();
                else
                    key = plainFlow();
                    if isempty(key)
                        fail("a flow mapping's key is empty", row);
                    end
                end
                flowSkip();
                item = [];
                if isequal(peek(), ':')
                    col = col + 1;
                    flowSkip();
                    if ~isequal(peek(), ',') && ~isequal(peek(), '}')
                        item = flowNode();
                    end
                    flowSkip();
                end
                if keyOk(key)
                    value.(key) = item;
                end
                c = peek();
                col = col + 1;
                if isequal(c, '}')
                    return
                end
                if ~isequal(c, ',')
                    fail("expected , or } in a flow mapping, not '" + string(c) + "'", row);
                end
            end
        end
        if c == '''' || c == '"'
            value = quoted();
            return
        end
        if any(c == '&*!%@`|>]},')
            fail("unexpected '" + string(c) + "' in a flow collection", row);
        end
        value = resolveScalar(plainFlow());
    end

    function text = plainFlow()
        % A plain scalar in a flow collection: up to , [ ] { } or ': ', and on over lines that go on with it
        text = '';
        while true
            line = lines{row};
            j = col;
            while j < numel(line)
                c = line(j + 1);
                after = at(line, j + 1);
                if any(c == ',[]{}') || (c == ':' && (isSpaceOrEnd(after) || any(after == ',[]{}'))) || ...
                        (c == '#' && j > 0 && (line(j) == ' ' || line(j) == char(9)))
                    break
                end
                j = j + 1;
            end
            piece = stripWs(line(col + 1:j));
            if isempty(text)
                text = piece;
            elseif ~isempty(piece)
                text = [text, ' ', piece]; %#ok<AGROW>
            end
            col = j;
            if j < numel(line) || row + 1 > numel(lines)
                return
            end
            following = stripWs(lines{row + 1});
            if isempty(following) || any(following(1) == ',[]{}:#')
                return
            end
            row = row + 1;
            col = 0;
        end
    end
end

% -- helpers ------------------------------------------------------------------------------------

function fail(message, row)
    nansen.internal.throwError("invalid-data", "not YAML that dev writes: %s (line %d)", message, row)
end

function c = at(line, k)
    % The character at k (from 0), or '' past the end
    if k >= 0 && k < numel(line)
        c = line(k + 1);
    else
        c = '';
    end
end

function tf = isSpaceOrEnd(c)
    tf = isempty(c) || c == ' ' || c == char(9);
end

function n = leadingSpaces(line)
    k = find(line ~= ' ', 1);
    if isempty(k)
        n = numel(line);
    else
        n = k - 1;
    end
end

function s = lstripWs(s)
    k = find(s ~= ' ' & s ~= char(9), 1);
    if isempty(k)
        s = '';
    else
        s = s(k:end);
    end
end

function s = rstripWs(s)
    k = find(s ~= ' ' & s ~= char(9), 1, 'last');
    if isempty(k)
        s = '';
    else
        s = s(1:k);
    end
end

function s = stripWs(s)
    s = rstripWs(lstripWs(s));
end

function tf = isEntry(rest)
    % A block sequence's entry: - followed by a space or nothing
    tf = ~isempty(rest) && rest(1) == '-' && isSpaceOrEnd(at(rest, 1));
end

function tf = isMarker(line)
    % A document marker: --- or ... at the start of a line
    tf = numel(line) >= 3 && (strcmp(line(1:3), '---') || strcmp(line(1:3), '...')) && isSpaceOrEnd(at(line, 3));
end

function out = cutComment(text)
    % The text before a comment (# after a space)
    for j = 2:numel(text)
        if text(j) == '#' && (text(j - 1) == ' ' || text(j - 1) == char(9))
            out = text(1:j - 1);
            return
        end
    end
    if ~isempty(text) && text(1) == '#'
        out = '';
    else
        out = text;
    end
end

function e = quotedEnd(line, i, quote)
    % Where (from 0) the closing quote is in the line from i (from 0), or -1 when it is not on it
    e = -1;
    while i < numel(line)
        c = line(i + 1);
        if quote == '"' && c == '\'
            i = i + 2;
            continue
        end
        if c == quote
            if quote == '''' && isequal(at(line, i + 1), '''')
                i = i + 2;
                continue
            end
            e = i;
            return
        end
        i = i + 1;
    end
end

function n = trailingEmpty(items)
    n = 0;
    while n < numel(items) && isempty(items{numel(items) - n})
        n = n + 1;
    end
end

function text = fold(parts, isDouble)
    % A quoted scalar's lines as YAML folds them: a line break is a space, an empty line a line break; in double
    % quotes, a \ at the end of a line joins it to the next
    if isscalar(parts)
        text = parts{1};
        return
    end
    count = numel(parts);
    lines = cell(1, count);
    joined = false(1, count);   % whether the line ends with an escaped line break
    for k = 1:count
        part = parts{k};
        if k > 1
            part = lstripWs(part);
        end
        if k < count
            stripped = rstripWs(part);
            slashes = numel(stripped) - numel(regexprep(stripped, '\\+$', ''));
            if isDouble && mod(slashes, 2) == 1
                part = stripped(1:end - 1);
                joined(k) = true;
            else
                part = stripped;
            end
        end
        lines{k} = part;
    end
    text = lines{1};
    empties = 0;
    for k = 2:count
        line = lines{k};
        if isempty(line) && k < count
            empties = empties + 1;
            continue
        end
        if empties > 0
            separator = repmat(newline, 1, empties);
        elseif joined(k - 1)
            separator = '';
        else
            separator = ' ';
        end
        text = [text, separator, line]; %#ok<AGROW>
        empties = 0;
    end
end

function out = unquote(quote, text, row)
    if quote == ''''
        out = strrep(text, '''''', '''');
        return
    end
    escapes = ['0', 'a', 'b', 't', char(9), 'n', 'v', 'f', 'r', 'e', ' ', '"', '/', '\', 'N', '_'];
    characters = char([0, 7, 8, 9, 9, 10, 11, 12, 13, 27, 32, 34, 47, 92, 133, 160]);
    out = '';
    i = 1;
    while i <= numel(text)
        c = text(i);
        if c ~= '\'
            out(end + 1) = c; %#ok<AGROW>
            i = i + 1;
            continue
        end
        e = at(text, i);
        k = [];
        if ~isempty(e)
            k = find(escapes == e, 1);
        end
        if ~isempty(k)
            out(end + 1) = characters(k); %#ok<AGROW>
            i = i + 2;
        elseif ~isempty(e) && any(e == 'xuU')
            size_ = 2 * (e == 'x') + 4 * (e == 'u') + 8 * (e == 'U');
            digits = text(i + 2:min(i + 1 + size_, numel(text)));
            if numel(digits) ~= size_ || isempty(regexp(digits, '^[0-9a-fA-F]+$', 'once'))
                fail(sprintf('the escape \\%s%s', e, digits), row);
            end
            code = hex2dec(digits);
            if code > 65535   % beyond 16 bits: a surrogate pair, as MATLAB keeps text
                code = code - 65536;
                out = [out, char(55296 + floor(code / 1024)), char(56320 + mod(code, 1024))]; %#ok<AGROW>
            else
                out(end + 1) = char(code); %#ok<AGROW>
            end
            i = i + 2 + size_;
        else
            fail(sprintf('the escape \\%s', e), row);
        end
    end
end

function value = resolveScalar(text)
    % A plain scalar's value, as YAML 1.1 (SnakeYAML) resolves it
    if isempty(text) || any(strcmp(text, {'~', 'null', 'Null', 'NULL'}))
        value = [];
    elseif any(strcmp(text, {'true', 'True', 'TRUE', 'yes', 'Yes', 'YES', 'on', 'On', 'ON'}))
        value = true;
    elseif any(strcmp(text, {'false', 'False', 'FALSE', 'no', 'No', 'NO', 'off', 'Off', 'OFF'}))
        value = false;
    elseif ~isempty(regexp(text, '^[-+]?(0|[1-9][0-9_]*)$', 'once')) || ...
            ~isempty(regexp(text, '^[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?$', 'once'))
        value = str2double(strrep(text, '_', ''));
    elseif ~isempty(regexp(text, '^[-+]?\.(inf|Inf|INF)$', 'once'))
        value = Inf;
        if text(1) == '-'
            value = -Inf;
        end
    elseif any(strcmp(text, {'.nan', '.NaN', '.NAN'}))
        value = NaN;
    else
        value = text;
    end
end

function tf = keyOk(key)
    % Whether a mapping's key can be a struct's field: a name that is not a keyword (as Python's, not iskeyword's
    % list, which may grow)
    keywords = {'break', 'case', 'catch', 'classdef', 'continue', 'else', 'elseif', 'end', 'for', 'function', ...
        'global', 'if', 'otherwise', 'parfor', 'persistent', 'return', 'spmd', 'switch', 'try', 'while'};
    tf = ischar(key) && ~isempty(regexp(key, '^[A-Za-z][A-Za-z0-9_]{0,62}$', 'once')) && ~any(strcmp(key, keywords));
end
