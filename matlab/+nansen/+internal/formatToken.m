function text = formatToken(value)
%formatToken A value as it appears in a file name or path template
    if islogical(value)
        text = "false";
        if value
            text = "true";
        end
    elseif isdatetime(value)
        dateFormat = nansen.internal.dateFormats();
        if string(value.Format) == string(dateFormat)
            [y, m, d] = ymd(value);
            text = sprintf("%04d-%02d-%02d", y, m, d);
        else
            text = nansen.internal.formatDatetime(value);
        end
    elseif isnumeric(value)
        if value == round(value)
            text = sprintf("%d", value);
        else
            text = nansen.formatNumber(value);
        end
    else
        text = string(value);
    end
end
