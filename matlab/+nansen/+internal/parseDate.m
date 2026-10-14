function value = parseDate(text, where)
%parseDate A YYYY-MM-DD string as a datetime, or invalid-value
    tokens = regexp(char(text), '^(\d{4})-(\d{2})-(\d{2})$', "tokens", "once");
    if ~isempty(tokens)
        parts = str2double(tokens);
        dateFormat = nansen.internal.dateFormats();
        value = datetime(parts(1), parts(2), parts(3), Format=dateFormat);
        [y, m, d] = ymd(value);
        if isequal([y, m, d], parts)
            return
        end
    end
    nansen.internal.throwError("invalid-value", "%s: '%s' is not a date (YYYY-MM-DD)", where, text)
end
