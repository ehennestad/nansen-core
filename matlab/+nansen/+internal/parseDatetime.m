function value = parseDatetime(text, where)
%parseDatetime A YYYY-MM-DDTHH:MM:SS[.fff] string as a datetime, or invalid-value
    tokens = regexp(char(text), '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{3})?$', "tokens", "once");
    if ~isempty(tokens)
        parts = str2double(tokens(1:6));
        milliseconds = 0;
        if numel(tokens) == 7 && ~isempty(tokens{7})
            milliseconds = str2double(tokens{7}(2:end));
        end
        [~, datetimeFormat] = nansen.internal.dateFormats();
        value = datetime(parts(1), parts(2), parts(3), parts(4), parts(5), parts(6), milliseconds, Format=datetimeFormat);
        [y, mo, d] = ymd(value);
        [h, mi, s] = hms(value);
        if isequal([y, mo, d, h, mi, floor(s)], parts)
            return
        end
    end
    nansen.internal.throwError("invalid-value", "%s: '%s' is not a datetime (YYYY-MM-DDTHH:MM:SS[.fff])", where, text)
end
