function value = medianOf(values)
%medianOf The middle value, or the mean of the two middle values, as Python's _median
    ordered = sort(values(:));
    n = numel(ordered);
    if mod(n, 2) == 1
        value = ordered((n + 1) / 2);
    else
        value = (ordered(n / 2) + ordered(n / 2 + 1)) / 2;
    end
end
