function pixels = detectRoi(image, point, radius)
%detectRoi An ROI found around a point of an image (height x width), as the viewer's Detect tool does
%
%   In the square of radius pixels around the point (0-based [row, column]),
%   the threshold is halfway from the 20th percentile of the square (linear
%   between sorted values, as NumPy's) to the brightest pixel within radius
%   of the point (dy^2 + dx^2 <= radius^2). The ROI is the 4-connected area
%   of pixels within radius that reach it, around the brightest pixel within
%   2 of the point (the first in row-major order of equal ones), with its
%   holes filled. Returns 0-based [row, column] pixels in row-major order,
%   as Python's nansen.frames.detect_roi.
    image = double(image);
    if ~ismatrix(image)
        nansen.internal.throwError("invalid-data", "an ROI is detected in an image (height x width)")
    end
    [height, width] = size(image);
    y = double(point(1));
    x = double(point(2));
    if y < 0 || y >= height || x < 0 || x >= width
        nansen.internal.throwError("invalid-params", "the point %s is not in the %d x %d image", jsonencode(point), height, width)
    end
    radius = max(1, round(double(radius)));
    top = max(0, y - radius);
    bottom = min(height, y + radius + 1);
    left = max(0, x - radius);
    right = min(width, x + radius + 1);
    window = image(top + 1:bottom, left + 1:right);
    [rows, columns] = ndgrid(top:bottom - 1, left:right - 1);
    near = (rows - y) .^ 2 + (columns - x) .^ 2;
    pixels = zeros(0, 2);
    values = sort(window(isfinite(window)));
    if isempty(values)
        return
    end
    position = (numel(values) - 1) * 0.2;
    k = floor(position);
    low = values(k + 1) + (position - k) * (values(min(k + 2, numel(values))) - values(k + 1));
    disk = near <= radius * radius;
    high = max(window(disk & isfinite(window)));
    mask = disk & window >= low + 0.5 * (high - low);
    seed = [];
    best = -Inf;
    for r = 1:size(window, 1)   % row-major
        for c = 1:size(window, 2)
            if near(r, c) <= 4 && window(r, c) > best
                seed = [r, c];
                best = window(r, c);
            end
        end
    end
    if isempty(seed) || ~mask(seed(1), seed(2))
        return
    end
    steps = [-1, 0; 1, 0; 0, -1; 0, 1];
    region = false(size(mask));
    region(seed(1), seed(2)) = true;
    todo = seed;
    while ~isempty(todo)
        here = todo(end, :);
        todo(end, :) = [];
        for s = 1:4
            n = here + steps(s, :);
            if n(1) >= 1 && n(1) <= size(mask, 1) && n(2) >= 1 && n(2) <= size(mask, 2) && mask(n(1), n(2)) && ~region(n(1), n(2))
                region(n(1), n(2)) = true;
                todo(end + 1, :) = n; %#ok<AGROW>
            end
        end
    end
    % holes: pixels not reachable from the window's edge through pixels outside the region
    outside = false(size(mask));
    edge = false(size(mask));
    edge([1, size(edge, 1)], :) = true;
    edge(:, [1, size(edge, 2)]) = true;
    [er, ec] = find(edge & ~region);
    todo = [er, ec];
    outside(edge & ~region) = true;
    while ~isempty(todo)
        here = todo(end, :);
        todo(end, :) = [];
        for s = 1:4
            n = here + steps(s, :);
            if n(1) >= 1 && n(1) <= size(mask, 1) && n(2) >= 1 && n(2) <= size(mask, 2) && ~region(n(1), n(2)) && ~outside(n(1), n(2))
                outside(n(1), n(2)) = true;
                todo(end + 1, :) = n; %#ok<AGROW>
            end
        end
    end
    [r, c] = find(~outside);
    pixels = sortrows([r + top - 1, c + left - 1]);
end
