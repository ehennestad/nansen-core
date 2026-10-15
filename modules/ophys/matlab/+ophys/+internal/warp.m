function out = warp(frames, dy, dx)
%warp out(y, x, t) = frames at (y + dy, x + dx, t), bilinearly, and 0 where that is outside the frame
%
%   Outside by more than a millionth of a pixel. dy and dx are height x
%   width x n, or 1 x 1 x n. Integer stacks are rounded half up, as Python's
%   ophys_methods.warp.
    [height, width, n] = size(frames, 1:3);
    [columns, rows] = meshgrid(0:width - 1, 0:height - 1);
    tolerance = 1e-6;
    values = zeros(height, width, n);
    for t = 1:n
        y = rows + dy(:, :, t);
        x = columns + dx(:, :, t);
        inside = y > -tolerance & y < height - 1 + tolerance & x > -tolerance & x < width - 1 + tolerance;
        y = min(max(y, 0), height - 1);
        x = min(max(x, 0), width - 1);
        y0 = floor(y);
        x0 = floor(x);
        fy = y - y0;
        fx = x - x0;
        y1 = min(y0 + 1, height - 1);
        x1 = min(x0 + 1, width - 1);
        f = double(frames(:, :, t));
        index = @(r, c) r + 1 + c * height;
        value = (1 - fy) .* ((1 - fx) .* f(index(y0, x0)) + fx .* f(index(y0, x1))) + fy .* ((1 - fx) .* f(index(y1, x0)) + fx .* f(index(y1, x1)));
        value(~inside) = 0;
        values(:, :, t) = value;
    end
    if isinteger(frames)
        out = cast(min(max(floor(values + 0.5), double(intmin(class(frames)))), double(intmax(class(frames)))), class(frames));
    else
        out = cast(values, class(frames));
    end
end
