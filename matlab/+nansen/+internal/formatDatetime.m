function text = formatDatetime(value)
%formatDatetime YYYY-MM-DDTHH:MM:SS, plus .fff when the milliseconds are non-zero
    [y, mo, d] = ymd(value);
    [h, mi, s] = hms(value);
    whole = floor(s);
    ms = min(floor(round((s - whole) * 1e6) / 1000), 999);
    text = sprintf("%04d-%02d-%02dT%02d:%02d:%02d", y, mo, d, h, mi, whole);
    if ms > 0
        text = text + sprintf(".%03d", ms);
    end
end
