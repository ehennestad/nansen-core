function text = encodeColumn(values, column)
%encodeColumn The CSV fields of one column, as a string column vector
    values = values(:);
    text = strings(numel(values), 1);
    switch column.DataType
        case "string"
            present = ~ismissing(values);
            text(present) = values(present);
            needsQuotes = false(size(values));
            needsQuotes(present) = values(present) == "" | contains(values(present), ["," """" newline char(13)]);
            text(needsQuotes) = """" + replace(values(needsQuotes), """", """""") + """";
        case "integer"
            present = ~isnan(values);
            text(present) = compose("%d", values(present));
        case "number"
            if any(isinf(values))
                nansen.internal.throwError("invalid-value", "column '%s': infinity cannot be written", column.Name)
            end
            present = find(~isnan(values));
            for i = reshape(present, 1, [])
                text(i) = nansen.formatNumber(values(i));
            end
        case "boolean"
            text(values) = "true";
            text(~values) = "false";
        case "date"
            present = ~isnat(values);
            [y, m, d] = ymd(values(present));
            text(present) = compose("%04d-%02d-%02d", y, m, d);
        case "datetime"
            present = find(~isnat(values));
            for i = reshape(present, 1, [])
                text(i) = nansen.internal.formatDatetime(values(i));
            end
    end
end
