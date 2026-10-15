function points = rotatePoints(points, angle, height, width)
%rotatePoints (row, column) points (n x 2, from 0) turned by angle degrees about the image centre and rounded half up
    if angle == 0
        points = floor(points + 0.5);
        return
    end
    radians = angle * pi / 180;
    c = cos(radians);
    s = sin(radians);
    cy = (height - 1) / 2;
    cx = (width - 1) / 2;
    y = points(:, 1) - cy;
    x = points(:, 2) - cx;
    points = floor([c * y - s * x + cy, s * y + c * x + cx] + 0.5);
end
