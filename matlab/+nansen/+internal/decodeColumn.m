function [values, ok] = decodeColumn(fields, quoted, dataType, isKey)
%decodeColumn All the CSV fields of one column at once, as decodeCell would decode each
%
%   [values, ok] = nansen.internal.decodeColumn(fields, quoted, dataType, isKey)
%   takes an n-by-1 cell of char fields and whether each was quoted, and
%   returns an n-by-1 column of the type's values. ok is false when any field
%   would make decodeCell raise an error. The caller then decodes the cells one
%   by one, so the first error in row order is the one reported.
    n = numel(fields);
    values = [];
    empty = cellfun('isempty', fields);
    absent = empty & ~(quoted & dataType == "string");
    ok = ~(any(absent) && (isKey || dataType == "boolean"));
    if ~ok
        return
    end
    present = ~absent;
    text = fields(present);
    [dateFormat, datetimeFormat] = nansen.internal.dateFormats();
    switch dataType
        case "string"
            values = string(fields);
            values(absent) = missing;
        case "integer"
            ok = all(matchesAll(text, '^-?(0|[1-9][0-9]{0,15})$'));
            if ok
                long = text(cellfun('length', regexprep(text, '^-', '')) == 16);
                ok = ~any(string(regexprep(long, '^-', '')) > "9007199254740992");
            end
            values = NaN(n, 1);
            if ok
                values(present) = str2double(text);
            end
        case "number"
            ok = all(matchesAll(text, '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'));
            values = NaN(n, 1);
            if ok
                values(present) = str2double(text);
                ok = all(isfinite(values(present)));
            end
        case "boolean"
            isTrue = strcmp(fields, 'true');
            ok = all(isTrue | strcmp(fields, 'false'));
            values = isTrue;
        case "date"
            ok = all(matchesAll(text, '^\d{4}-\d{2}-\d{2}$'));
            values = NaT(n, 1, Format=dateFormat);
            if ok
                [values(present), ok] = parse(text, 'yyyy-MM-dd', 'yyyy-MM-dd');
            end
        case "datetime"
            ok = all(matchesAll(text, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?$'));
            values = NaT(n, 1, Format=datetimeFormat);
            if ok
                withMilliseconds = cellfun('length', text) == 23;
                parsed = NaT(numel(text), 1, Format=datetimeFormat);
                [parsed(withMilliseconds), okMs] = parse(text(withMilliseconds), ...
                    'yyyy-MM-dd''T''HH:mm:ss.SSS', 'yyyy-MM-dd''T''HH:mm:ss.SSS');
                [parsed(~withMilliseconds), okS] = parse(text(~withMilliseconds), ...
                    'yyyy-MM-dd''T''HH:mm:ss', 'yyyy-MM-dd''T''HH:mm:ss');
                ok = okMs && okS;
                values(present) = parsed;
            end
        otherwise
            ok = false;
    end
end

function tf = matchesAll(text, pattern)
    tf = ~cellfun('isempty', regexp(text, pattern, 'once'));
end

function [values, ok] = parse(text, inputFormat, checkFormat)
    % Parse, then require each value to print back as its text: 2025-02-30 is not a date.
    values = NaT(numel(text), 1);
    ok = true;
    if isempty(text)
        return
    end
    try
        values = datetime(text(:), InputFormat=inputFormat);
    catch
        ok = false;
        return
    end
    ok = ~any(isnat(values)) && isequal(cellstr(char(values, checkFormat)), text(:));
end
