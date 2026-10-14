function value = jsonValue(value, column)
%jsonValue One cell as a JSON value: [] for missing, text for dates and datetimes
    if nansen.internal.isMissingValue(value)
        value = [];
        return
    end
    switch column.DataType
        case "string"
            value = char(value);
        case "date"
            [y, m, d] = ymd(value);
            value = sprintf('%04d-%02d-%02d', y, m, d);
        case "datetime"
            value = char(nansen.internal.formatDatetime(value));
    end
end
