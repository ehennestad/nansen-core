function out = movingPercentile(traces, percentile, window)
%movingPercentile The percentile of each column, over all rows (window 0) or over the window rows centred on each row
%
%   The window of row t (0-based) is rows t - floor(window/2) up to, not
%   including, t - floor(window/2) + window, cut at the ends.
    frames = size(traces, 1);
    if window == 0 || window >= 2 * frames
        out = repmat(ophys.internal.percentileOf(traces, percentile), frames, 1);
        return
    end
    out = zeros(size(traces));
    for t = 0:frames - 1
        first = max(0, t - floor(window / 2));
        last = min(frames, t - floor(window / 2) + window);
        out(t + 1, :) = ophys.internal.percentileOf(traces(first + 1:last, :), percentile);
    end
end
