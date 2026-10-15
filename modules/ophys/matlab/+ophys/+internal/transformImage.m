function out = transformImage(image, shift, angle)
%transformImage The image moved back by shift and turned back by angle degrees about its centre
%
%   out(p) = image at rotation(angle) * (p + shift - centre) + centre,
%   bilinearly, and the image's mean where that is outside it; rotation is
%   [cos, -sin; sin, cos] on (row, column) vectors, as Python's
%   ophys_methods.transform_image.
    [height, width] = size(image);
    radians = angle * (pi / 180);   % as Python's math.radians
    c = cos(radians);
    s = sin(radians);
    cy = (height - 1) / 2;
    cx = (width - 1) / 2;
    [columns, rows] = meshgrid(0:width - 1, 0:height - 1);
    y = rows + shift(1) - cy;
    x = columns + shift(2) - cx;
    dy = c * y - s * x + cy - rows;
    dx = s * y + c * x + cx - columns;
    out = ophys.internal.warp(double(image), dy, dx);
    inside = ophys.internal.warp(ones(height, width), dy, dx) > 0.5;
    out(~inside) = mean(double(image), "all");
end
