function value = missingValue(dataType)
%missingValue The value standing for a missing cell in a column of this type
    [dateFormat, datetimeFormat] = nansen.internal.dateFormats();
    switch dataType
        case "string"
            value = string(missing);
        case {"integer", "number"}
            value = NaN;
        case "date"
            value = NaT(Format=dateFormat);
        case "datetime"
            value = NaT(Format=datetimeFormat);
        otherwise
            error("nansen:internal:NoMissingValue", "%s columns have no missing value", dataType)
    end
end
