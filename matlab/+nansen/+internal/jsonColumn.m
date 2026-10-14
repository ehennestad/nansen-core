function values = jsonColumn(column, dataType)
%jsonColumn A whole table column as JSON values (an n-by-1 cell), as jsonValue gives each cell
%
%   Missing values are []; dates are YYYY-MM-DD and datetimes
%   YYYY-MM-DDTHH:MM:SS with .fff when the milliseconds are not zero.
    n = numel(column);
    column = reshape(column, n, 1);
    switch dataType
        case "string"
            missingMask = ismissing(column);
            values = cellstr(column);
        case {"integer", "number"}
            missingMask = isnan(column);
            values = num2cell(double(column));
        case "boolean"
            missingMask = false(n, 1);
            values = num2cell(logical(column));
        case "date"
            missingMask = isnat(column);
            [y, m, d] = ymd(column);
            values = cellstr(compose("%04d-%02d-%02d", y, m, d));
        case "datetime"
            missingMask = isnat(column);
            [y, mo, d] = ymd(column);
            [h, mi, s] = hms(column);
            whole = floor(s);
            ms = min(floor(round((s - whole) * 1e6) / 1000), 999);
            text = compose("%04d-%02d-%02dT%02d:%02d:%02d", y, mo, d, h, mi, whole);
            withMs = ms > 0;
            text(withMs) = text(withMs) + compose(".%03d", ms(withMs));
            values = cellstr(text);
        otherwise
            error("nansen:internal:UnknownDataType", "Unknown data type %s", dataType)
    end
    values = reshape(values, n, 1);
    values(missingMask) = {[]};
end
