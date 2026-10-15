function points = turnPoints(points, angle, height, width)
%turnPoints Points (n x 2: rows, columns) turned by angle degrees about the image centre: [cos, -sin; sin, cos]
%
%   Not rounded; as Python's nansen.frames._turned (the radians as
%   math.radians computes them).
    if angle == 0
        return
    end
    radians = angle * (pi / 180);
    c = cos(radians);
    s = sin(radians);
    cy = (height - 1) / 2;
    cx = (width - 1) / 2;
    y = points(:, 1) - cy;
    x = points(:, 2) - cx;
    points = [c * y - s * x + cy, s * y + c * x + cx];
end
