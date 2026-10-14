function text = timestamp()
%timestamp The current local time as YYYY-MM-DDTHH:MM:SS.fff
    text = string(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss.SSS"));
end
