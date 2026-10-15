function [pixels, ridge] = somaMask(im, cy, cx)
%somaMask A soma's pixels (1-based [row, column]) around the 0-based centre (cy, cx), and its ridge share
%
%   From where the image rises (the nucleus's edge) and then falls (the
%   soma's edge) along 48 directions, sampled every 0.25 px out to 10 px:
%   see Python's ophys_methods.soma_mask, which this follows step for step.
    angleCount = 48;
    step = 0.25;
    count = 40;
    angles = 2 * pi * (0:angleCount - 1) / angleCount;
    radii = step * (0:count)';
    y = cy + radii * sin(angles);
    x = cx + radii * cos(angles);
    y0 = floor(y);
    x0 = floor(x);
    fy = y - y0;
    fx = x - x0;
    height = size(im, 1);
    at = @(r, c) im(r + 1 + c * height);   % 0-based (row, column) to a linear index
    profile = (1 - fy) .* ((1 - fx) .* at(y0, x0) + fx .* at(y0, x0 + 1)) + fy .* ((1 - fx) .* at(y0 + 1, x0) + fx .* at(y0 + 1, x0 + 1));
    profile = ophys.internal.blur5(ophys.internal.blur5(profile, 1, false), 2, true);
    rise = diff(profile, 1, 1);   % rise(i, :) is between samples i - 1 and i (0-based)
    [strength, first] = max(rise, [], 1);
    first = first - 1;
    spread = std(strength);
    if spread > 0
        significant = mean(strength) / spread > 1.5;
    else
        significant = mean(strength) > 0;
    end
    if significant
        nucleus = circularMean(first, 5);
        start = floor(nucleus + 0.5);
        depth = min(count - floor(min(nucleus)), ceil(mean(nucleus) * 1.2));
    else
        nucleus = zeros(1, angleCount);
        start = zeros(1, angleCount);
        depth = count;
    end
    beyond = zeros(1, angleCount);
    for j = 1:angleCount
        stop = min(start(j) + max(depth, 1), count);
        if stop > start(j)
            [~, k] = min(rise(start(j) + 1:stop, j));
            beyond(j) = k - 1;
        end
    end
    edge = min(max(circularMean(beyond, 5) + nucleus, 0), count - 1);
    middle = floor((nucleus + edge + 1) / 2 + 0.5);
    columns = 1:angleCount;
    pick = @(rows) profile(sub2ind(size(profile), rows + 1, columns));
    ring = pick(middle);
    ridge = mean(ring > pick(floor(nucleus + 0.5)) & ring > pick(min(floor(edge + 0.5) + 1, count)));
    radius = (edge + 0.5) * step + 0.5;
    xs = cx + radius .* cos(angles);
    ys = cy + radius .* sin(angles);
    reach = ceil(max(radius));
    pixels = zeros(0, 2);
    for r = cy - reach:cy + reach
        for c = cx - reach:cx + reach
            if r >= 0 && r < size(im, 1) && c >= 0 && c < size(im, 2) && ophys.internal.inPolygon(xs, ys, c, r)
                pixels(end + 1, :) = [r + 1, c + 1]; %#ok<AGROW>
            end
        end
    end
end

function out = circularMean(values, window)
    half = floor(window / 2);
    n = numel(values);
    out = zeros(1, n);
    for j = 1:n
        total = 0;
        for k = -half:half
            total = total + values(mod(j - 1 + k, n) + 1);
        end
        out(j) = total / window;
    end
end
