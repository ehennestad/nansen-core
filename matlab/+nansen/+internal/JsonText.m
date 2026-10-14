classdef JsonText
%JsonText Edits to JSON text that keep everything else in the text as it was
%
%   MATLAB cannot write a decoded file back unchanged (jsondecode loses
%   which arrays had one element), and shared files such as a DSM config
%   should not be reformatted anyway. These functions find a value by JSON
%   Pointer (RFC 6901) and replace it, append to an array, or set an object
%   member. Python's nansen.jsontext does the same, byte for byte; the cases
%   in conformance/jsontext hold the two to it.
%
%   Values are MATLAB values: struct (object), cell (array), text, logical,
%   numbers, [] or <missing> (null). They are written on one line.

    methods (Static)
        function text = replace(text, pointer, value)
            text = char(text);
            [first, last] = nansen.internal.JsonText.find(text, pointer);
            text = [text(1:first - 1), char(nansen.internal.JsonText.encode(value)), text(last + 1:end)];
        end

        function text = append(text, pointer, value)
            % Add a value at the end of the array at the pointer
            text = char(text);
            [first, last] = nansen.internal.JsonText.find(text, pointer);
            if text(first) ~= '['
                nansen.internal.throwError("json-pointer-not-found", "%s is not an array", pointer)
            end
            text = insertItem(text, first, last, char(nansen.internal.JsonText.encode(value)));
        end

        function text = setMember(text, pointer, key, value)
            % Set a member of the object at the pointer: replace it if it is there, else add it at the end
            text = char(text);
            [first, last] = nansen.internal.JsonText.find(text, pointer);
            if text(first) ~= '{'
                nansen.internal.throwError("json-pointer-not-found", "%s is not an object", pointer)
            end
            escaped = replace(replace(string(key), "~", "~0"), "/", "~1");
            try
                text = nansen.internal.JsonText.replace(text, regexprep(char(pointer), '/$', '') + "/" + escaped, value);
            catch err
                if ~isa(err, "nansen.NansenError") || err.Code ~= "json-pointer-not-found"
                    rethrow(err)
                end
                item = [jsonString(key), ': ', char(nansen.internal.JsonText.encode(value))];
                text = insertItem(text, first, last, item);
            end
        end

        function [first, last] = find(text, pointer)
            % The span text(first:last) of the value at the pointer
            text = char(text);
            position = skipWhitespace(text, 1);
            for segment = segments(pointer)
                if position > numel(text)
                    nansen.internal.throwError("json-pointer-not-found", "no value at %s", pointer)
                end
                if text(position) == '{'
                    position = member(text, position, segment, pointer);
                elseif text(position) == '['
                    if isempty(regexp(char(segment), '^\d+$', "once"))
                        nansen.internal.throwError("json-pointer-not-found", "%s: '%s' is not an array index", pointer, segment)
                    end
                    position = element(text, position, str2double(segment), pointer);
                else
                    nansen.internal.throwError("json-pointer-not-found", ...
                        "%s: '%s' is inside a value that is not an object or array", pointer, segment)
                end
            end
            first = position;
            last = skipValue(text, position) - 1;
        end

        function text = encode(value)
            % A value as one line of JSON, the way Python's nansen.jsontext.encode writes it
            if isstruct(value) && isscalar(value)
                names = fieldnames(value);
                parts = cellfun(@(name) [jsonString(name), ': ', char(nansen.internal.JsonText.encode(value.(name)))], ...
                    names, UniformOutput=false);
                text = ['{', strjoin(reshape(parts, 1, []), ', '), '}'];
            elseif iscell(value)
                parts = cellfun(@(v) char(nansen.internal.JsonText.encode(v)), value, UniformOutput=false);
                text = ['[', strjoin(reshape(parts, 1, []), ', '), ']'];
            elseif (ischar(value) && (isrow(value) || isempty(value))) || (isstring(value) && isscalar(value) && ~ismissing(value))
                text = jsonString(value);
            elseif (isstring(value) && isscalar(value)) || (isnumeric(value) && isempty(value))
                text = 'null';
            elseif islogical(value) && isscalar(value)
                text = 'false';
                if value
                    text = 'true';
                end
            elseif isnumeric(value) && isscalar(value)
                if value == round(value) && abs(value) < 2^53
                    text = sprintf('%d', value);
                else
                    text = jsonencode(value);
                end
            elseif (isnumeric(value) || islogical(value)) && isvector(value)
                text = nansen.internal.JsonText.encode(num2cell(value));
            else
                error("nansen:internal:JsonText:Unsupported", "Cannot write a %s as JSON text", class(value))
            end
            text = string(text);
        end
    end
end

function text = jsonString(value)
    text = jsonencode(char(value));
end

function parts = segments(pointer)
    pointer = string(pointer);
    if pointer == "" || pointer == "/"
        parts = strings(1, 0);
        return
    end
    if ~startsWith(pointer, "/")
        nansen.internal.throwError("json-pointer-not-found", "a JSON Pointer starts with '/': %s", pointer)
    end
    parts = split(extractAfter(pointer, 1), "/")';
    parts = replace(replace(parts, "~1", "/"), "~0", "~");
end

function i = skipWhitespace(text, i)
    while i <= numel(text) && any(text(i) == [' ', char(9), char(13), char(10)])
        i = i + 1;
    end
end

function i = skipString(text, i)
    % i at the opening quote; returns the position after the closing one
    i = i + 1;
    while i <= numel(text)
        if text(i) == '\'
            i = i + 2;
        elseif text(i) == '"'
            i = i + 1;
            return
        else
            i = i + 1;
        end
    end
    nansen.internal.throwError("malformed-json", "unterminated string")
end

function i = skipValue(text, i)
    % i at the start of a value; returns the position after it
    if text(i) == '"'
        i = skipString(text, i);
        return
    end
    if text(i) == '{' || text(i) == '['
        depth = 0;
        while i <= numel(text)
            c = text(i);
            if c == '"'
                i = skipString(text, i);
                continue
            end
            if c == '{' || c == '['
                depth = depth + 1;
            elseif c == '}' || c == ']'
                depth = depth - 1;
                if depth == 0
                    i = i + 1;
                    return
                end
            end
            i = i + 1;
        end
        nansen.internal.throwError("malformed-json", "unterminated object or array")
    end
    while i <= numel(text) && ~any(text(i) == [',', '}', ']', ' ', char(9), char(13), char(10)])
        i = i + 1;
    end
end

function i = member(text, i, key, pointer)
    i = skipWhitespace(text, i + 1);
    while i <= numel(text) && text(i) ~= '}'
        stop = skipString(text, i);
        name = jsondecode(text(i:stop - 1));
        i = skipWhitespace(text, stop);
        i = skipWhitespace(text, i + 1);   % the colon
        if string(name) == key
            return
        end
        i = skipWhitespace(text, skipValue(text, i));
        if i <= numel(text) && text(i) == ','
            i = skipWhitespace(text, i + 1);
        end
    end
    nansen.internal.throwError("json-pointer-not-found", "no member '%s' at %s", key, pointer)
end

function i = element(text, i, index, pointer)
    i = skipWhitespace(text, i + 1);
    n = 0;
    while i <= numel(text) && text(i) ~= ']'
        if n == index
            return
        end
        i = skipWhitespace(text, skipValue(text, i));
        if i <= numel(text) && text(i) == ','
            i = skipWhitespace(text, i + 1);
        end
        n = n + 1;
    end
    nansen.internal.throwError("json-pointer-not-found", "no element %d at %s", index, pointer)
end

function text = insertItem(text, first, last, item)
    % Insert an item before the closing bracket of the object or array text(first:last)
    lastItem = last - 1;
    while lastItem > first && any(text(lastItem) == [' ', char(9), char(13), char(10)])
        lastItem = lastItem - 1;
    end
    if lastItem == first   % empty
        text = [text(1:first), item, text(last:end)];
        return
    end
    firstItem = skipWhitespace(text, first + 1);
    newline = find(text(first:firstItem - 1) == char(10), 1, "last");
    if ~isempty(newline)   % one item per line: the new one goes on a line of its own, indented like the first
        indent = text(first + newline:firstItem - 1);
        text = [text(1:lastItem), ',', char(10), indent, item, text(lastItem + 1:end)];
    else
        text = [text(1:lastItem), ', ', item, text(lastItem + 1:end)];
    end
end
