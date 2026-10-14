function value = checkValue(value, column, isKey)
%checkValue Convert a MATLAB value to a column's type, or raise invalid-value
%
%   Accepts text for string, date and datetime columns, numbers for integer
%   and number columns, logical scalars for booleans, and datetimes without
%   a time zone. [], <missing>, NaN and NaT are missing values.
    where = sprintf("column '%s'", column.Name);
    dataType = column.DataType;
    if nansen.internal.isMissingValue(value)
        if isKey
            nansen.internal.throwError("missing-key", "%s: the key is missing", where)
        end
        if dataType == "boolean"
            nansen.internal.throwError("missing-value", "%s: boolean cells must have a value", where)
        end
        value = nansen.internal.missingValue(dataType);
        return
    end
    isText = (ischar(value) && (isrow(value) || isempty(value))) || (isstring(value) && isscalar(value));
    isNumber = isnumeric(value) && isscalar(value) && isreal(value);
    [dateFormat, datetimeFormat] = nansen.internal.dateFormats();
    switch dataType
        case "string"
            if isText
                value = string(value);
                return
            end
        case "integer"
            if isNumber && isfinite(value) && double(value) == round(double(value)) && abs(double(value)) <= 2^53
                value = double(value);
                return
            end
        case "number"
            if isNumber && isfinite(value)
                value = double(value);
                return
            end
        case "boolean"
            if islogical(value) && isscalar(value)
                return
            end
        case "date"
            if isText
                value = nansen.internal.parseDate(value, where);
                return
            end
            if isdatetime(value) && isscalar(value) && isempty(value.TimeZone)
                value = dateshift(value, "start", "day");
                value.Format = dateFormat;
                return
            end
        case "datetime"
            if isText
                value = nansen.internal.parseDatetime(value, where);
                return
            end
            if isdatetime(value) && isscalar(value) && isempty(value.TimeZone)
                [y, mo, d] = ymd(value);
                [h, mi, s] = hms(value);
                whole = floor(s);
                ms = min(floor(round((s - whole) * 1e6) / 1000), 999);
                value = datetime(y, mo, d, h, mi, whole, ms, Format=datetimeFormat);
                return
            end
    end
    nansen.internal.throwError("invalid-value", "%s: a %s is not a valid %s", where, class(value), dataType)
end
