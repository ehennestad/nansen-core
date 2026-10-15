function pixels = polygonPixels(xs, ys, height, width)
%polygonPixels The 0-based [row, column] pixels whose centre is inside a polygon, by the even-odd rule
%
%   A pixel's centre is x column + 1, y row + 1 in the polygon's 1-based
%   x, y; only the pixels around its bounding box are tried, row by row.
%   As Python's ophys_adapters.polygon_pixels.
    pixels = zeros(0, 2);
    xs = double(xs(:));
    ys = double(ys(:));
    if isempty(xs)
        return
    end
    firstRow = max(0, floor(min(ys)) - 2);
    lastRow = min(height - 1, ceil(max(ys)));
    firstColumn = max(0, floor(min(xs)) - 2);
    lastColumn = min(width - 1, ceil(max(xs)));
    for r = firstRow:lastRow
        for c = firstColumn:lastColumn
            if ophys.internal.inPolygon(xs, ys, c + 1, r + 1)
                pixels(end + 1, :) = [r, c]; %#ok<AGROW>
            end
        end
    end
end
