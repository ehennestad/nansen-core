function [records, quoted] = parseCsv(text)
%parseCsv Split CSV text into records of fields (docs/reference/table-format.md)
%
%   [records, quoted] = nansen.internal.parseCsv(text) returns a cell
%   array of records, each a cell row of char fields, and for each record a
%   logical row saying which fields were quoted. An unquoted empty field is a
%   missing value; a quoted one is the empty string.
    text = char(text);
    if isempty(text)
        nansen.internal.throwError("malformed-csv", "the CSV is empty; it must at least have a header")
    end
    if text(1) == char(65279)
        nansen.internal.throwError("malformed-csv", "the CSV starts with a byte order mark")
    end
    LF = char(10);
    CR = char(13);
    Q = '"';

    if ~any(text == Q) && ~any(text == CR)
        % Nothing is quoted: records are lines, fields are split on commas.
        lines = strsplit(text, LF, CollapseDelimiters=false);
        if text(end) == LF
            lines(end) = [];
        end
        records = cellfun(@(line) strsplit(line, ",", CollapseDelimiters=false), lines, UniformOutput=false);
        quoted = cellfun(@(record) false(1, numel(record)), records, UniformOutput=false);
        return
    end

    records = {};
    quoted = {};
    record = {};
    recordQuoted = false(1, 0);
    n = numel(text);
    i = 1;
    while true
        if i <= n && text(i) == Q
            % A quoted field runs to the closing quote; "" stands for one quote.
            i = i + 1;
            parts = {};
            segmentStart = i;
            closed = false;
            while i <= n
                if text(i) == Q
                    if i < n && text(i + 1) == Q
                        parts{end + 1} = text(segmentStart:i); %#ok<AGROW> keeps one quote
                        i = i + 2;
                        segmentStart = i;
                        continue
                    end
                    parts{end + 1} = text(segmentStart:i - 1); %#ok<AGROW>
                    i = i + 1;
                    closed = true;
                    break
                end
                i = i + 1;
            end
            if ~closed
                nansen.internal.throwError("malformed-csv", "unterminated quoted field in record %d", numel(records) + 1)
            end
            if i <= n && text(i) ~= ',' && text(i) ~= LF && text(i) ~= CR
                nansen.internal.throwError("malformed-csv", "text after a closing quote in record %d", numel(records) + 1)
            end
            value = [parts{:}];
            if isempty(value)
                value = '';
            end
            isQuoted = true;
        else
            start = i;
            while i <= n && text(i) ~= ',' && text(i) ~= LF && text(i) ~= CR
                if text(i) == Q
                    nansen.internal.throwError("malformed-csv", ...
                        "a double quote inside an unquoted field in record %d", numel(records) + 1)
                end
                i = i + 1;
            end
            value = text(start:i - 1);
            if isempty(value)
                value = '';
            end
            isQuoted = false;
        end

        record{end + 1} = value; %#ok<AGROW>
        recordQuoted(end + 1) = isQuoted; %#ok<AGROW>

        if i > n
            % The last record had no line end.
            records{end + 1} = record; %#ok<AGROW>
            quoted{end + 1} = recordQuoted; %#ok<AGROW>
            break
        end
        if text(i) == ','
            i = i + 1;
            continue
        end
        if text(i) == CR
            if i == n || text(i + 1) ~= LF
                nansen.internal.throwError("malformed-csv", ...
                    "a carriage return without a line feed in record %d", numel(records) + 1)
            end
            i = i + 1;
        end
        i = i + 1;
        records{end + 1} = record; %#ok<AGROW>
        quoted{end + 1} = recordQuoted; %#ok<AGROW>
        record = {};
        recordQuoted = false(1, 0);
        if i > n
            break
        end
    end
end
