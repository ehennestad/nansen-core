function result = percentileOf(values, percentile)
%percentileOf Linear interpolation between the sorted values of each column, at (n - 1) * percentile / 100
%
%   As numpy.percentile does; NaN for a column with a NaN.
    ordered = sort(values, 1);
    n = size(ordered, 1);
    position = (n - 1) * percentile / 100;
    low = floor(position);
    high = min(low + 1, n - 1);
    result = ordered(low + 1, :) + (position - low) * (ordered(high + 1, :) - ordered(low + 1, :));
    result(any(isnan(values), 1)) = NaN;
end
