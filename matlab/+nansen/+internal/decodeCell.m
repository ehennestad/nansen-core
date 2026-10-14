function value = decodeCell(text, wasQuoted, column, isKey, where)
%decodeCell The value of one CSV field in a column (docs/reference/table-format.md#values-by-type)
    dataType = column.DataType;
    if isempty(text) && ~(wasQuoted && dataType == "string")
        if isKey
            nansen.internal.throwError("missing-key", "%s: the key is empty", where)
        end
        if dataType == "boolean"
            nansen.internal.throwError("missing-value", "%s: boolean cells must have a value", where)
        end
        value = nansen.internal.missingValue(dataType);
        return
    end
    switch dataType
        case "string"
            value = string(text);
        case "integer"
            digits = regexp(text, '^-?(0|[1-9][0-9]*)$', "tokens", "once");
            if isempty(digits) || strlength(digits{1}) > 16 ...
                    || (strlength(digits{1}) == 16 && string(digits{1}) > "9007199254740992")
                nansen.internal.throwError("invalid-value", "%s: '%s' is not an integer within +-2^53", where, text)
            end
            value = str2double(text);
        case "number"
            value = NaN;
            if ~isempty(regexp(text, '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$', "once"))
                value = str2double(text);
            end
            if ~isfinite(value)
                nansen.internal.throwError("invalid-value", "%s: '%s' is not a finite number", where, text)
            end
        case "boolean"
            if strcmp(text, "true")
                value = true;
            elseif strcmp(text, "false")
                value = false;
            else
                nansen.internal.throwError("invalid-value", "%s: '%s' is not true or false", where, text)
            end
        case "date"
            value = nansen.internal.parseDate(text, where);
        case "datetime"
            value = nansen.internal.parseDatetime(text, where);
    end
end
