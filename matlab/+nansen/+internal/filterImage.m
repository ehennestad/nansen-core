function image = filterImage(image, name)
%filterImage imviewer's 2-D filters of an image
%
%   smooth: a binomial blur ([1 4 6 4 1] / 16 along rows, then columns);
%   gradient: the magnitude of the central differences ((next - previous)
%   / 2). Edges repeat the last pixel. Exact sums in a fixed order, as
%   Python's nansen.frames.filter_image.
    image = double(image);
    [height, width] = size(image);
    switch string(name)
        case "smooth"
            rows = [1, 1, 1:height, height, height];
            p = image(rows, :);
            image = (p(1:height, :) + 4 * p(2:height + 1, :) + 6 * p(3:height + 2, :) + 4 * p(4:height + 3, :) + p(5:height + 4, :)) / 16;
            columns = [1, 1, 1:width, width, width];
            p = image(:, columns);
            image = (p(:, 1:width) + 4 * p(:, 2:width + 1) + 6 * p(:, 3:width + 2) + 4 * p(:, 4:width + 3) + p(:, 5:width + 4)) / 16;
        case "gradient"
            p = image([1, 1:height, height], [1, 1:width, width]);
            dy = (p(3:end, 2:end - 1) - p(1:end - 2, 2:end - 1)) / 2;
            dx = (p(2:end - 1, 3:end) - p(2:end - 1, 1:end - 2)) / 2;
            image = sqrt(dy .* dy + dx .* dx);
        otherwise
            nansen.internal.throwError("invalid-params", "filter is smooth or gradient, not '%s'", name)
    end
end
