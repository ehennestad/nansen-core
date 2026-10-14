function text = formatNumber(value)
%formatNumber The canonical text of a number in a table
%
%   The shortest form that reads back as exactly the same double; see
%   docs/reference/table-format.md#writing-numbers.
    arguments
        value (1,1) double
    end
    if ~isfinite(value)
        error("nansen:formatNumber:NotFinite", "Cannot write %g as a table number", value)
    end
    for precision = 1:17
        exponential = sprintf('%.*e', precision - 1, value);
        if str2double(exponential) == value
            break
        end
    end
    exponent = sscanf(exponential(find(exponential == 'e', 1) + 1:end), '%d');
    if exponent >= -4 && exponent < 17
        text = sprintf('%.*f', max(precision - 1 - exponent, 0), value);
    else
        text = exponential;
    end
    text = string(text);
end
