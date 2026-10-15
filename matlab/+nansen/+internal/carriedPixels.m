function pixels = carriedPixels(pixels, source, target, height, width)
%carriedPixels An ROI's pixels (n x 2, from 0) in one aligned entity's image where they are in another's
%
%   source and target are the two entities' entries of an ROI file's
%   alignment. Through the reference's image, rounded half up, each once,
%   in row-major order, and those outside the image left out. As Python's
%   nansen.frames.carried_pixels.
    pixels = reshape(double(pixels), [], 2);
    if isempty(pixels)
        pixels = zeros(0, 2);
        return
    end
    points = floor(nansen.internal.alignedPoints(nansen.internal.referencePoints(pixels, source, height, width), target, height, width) + 0.5);
    points = points(points(:, 1) >= 0 & points(:, 1) < height & points(:, 2) >= 0 & points(:, 2) < width, :);
    pixels = unique(points, "rows");
    if isempty(pixels)
        pixels = zeros(0, 2);
    end
end
