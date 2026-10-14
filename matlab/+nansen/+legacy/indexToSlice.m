function sliced = indexToSlice(expression)
%indexToSlice A dev index range as a DSM substring slice, or <missing>
%
%   '1:5' -> ':5', '3:end' -> '2:', 'end-3:end' -> '-4:', '4' -> '3:4'.
%   Anything other than a plain range ('[1:3 5:7]', '1:2:9') has no slice
%   form and gives <missing>.
    arguments
        expression (1,1) string
    end
    sliced = string(missing);
    bounds = split(replace(expression, " ", ""), ":");
    isBound = @(b) ~isempty(regexp(char(b), '^(\d+|end(-\d+)?)$', "once"));
    if numel(bounds) > 2 || ~all(arrayfun(isBound, bounds))
        return
    end
    first = bounds(1);
    last = bounds(end);
    if ~isnan(str2double(first)) && str2double(first) < 1
        return
    end
    start = offset(first);
    stop = offset(last);
    if (start >= 0) == (stop >= 0) && stop < start
        return
    end
    startText = "";
    if start ~= 0
        startText = string(start);
    end
    stopText = "";
    if stop ~= -1
        stopText = string(stop + 1);
    end
    sliced = startText + ":" + stopText;
end

function value = offset(bound)
    % The 0-based index of a 1-based bound; negative counts from the end
    if bound == "end"
        value = -1;
    elseif startsWith(bound, "end-")
        value = -1 - str2double(extractAfter(bound, 4));
    else
        value = str2double(bound) - 1;
    end
end
