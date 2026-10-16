function image = filterImage(image, name)
%filterImage imviewer's 2-D filters of an image (dev's stack.process.filter2 and its own)
%
%   smooth: a binomial blur ([1 4 6 4 1] / 16 along rows, then columns);
%   gradient: the magnitude of the central differences ((next - previous)
%   / 2); gauss2d and gaussian: dev's gauss2d (a Gaussian blur of sigma
%   0.5, as imgaussfilt's 3 x 3) and gauss2dtest (sigma 1, 5 x 5), along
%   rows, then columns; absGradient: dev's absgradient, the magnitude of
%   the derivative along the rows (gradient's central differences,
%   one-sided at the first and last column), its lowest and highest 1%
%   saturated and the rest stretched to 0..255 (imadjustn, im2uint8);
%   clahe: dev's clahe (nansen.internal.claheImage). Edges repeat the last
%   pixel. Exact sums in a fixed order, written out (no Image Processing
%   Toolbox), as Python's nansen.frames.filter_image.
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
        case "gauss2d"
            % exp(-x^2 / (2 sigma^2)) over x = -2 sigma..2 sigma, divided by their sum, as Python's GAUSS_HALF
            image = blur(image, [0.10650697891920076, 0.7869860421615985, 0.10650697891920076]);
        case "gaussian"
            image = blur(image, [0.054488684549642945, 0.24420134200323335, 0.40261994689424746, 0.24420134200323335, 0.054488684549642945]);
        case "absGradient"
            dx = zeros(height, width);
            if width > 1
                dx(:, 2:width - 1) = (image(:, 3:width) - image(:, 1:width - 2)) / 2;
                dx(:, 1) = image(:, 2) - image(:, 1);
                dx(:, width) = image(:, width) - image(:, width - 1);
            end
            image = saturated(abs(dx));
        case "clahe"
            image = nansen.internal.claheImage(image);
        otherwise
            nansen.internal.throwError("invalid-params", ...
                "filter is smooth, gradient, gauss2d, gaussian, absGradient or clahe, not '%s'", name)
    end
end

function image = blur(image, weights)
    % The weights along the rows, then along the columns, the edges repeated: the products added in the weights' order
    [height, width] = size(image);
    reach = (numel(weights) - 1) / 2;
    p = image([ones(1, reach), 1:height, height * ones(1, reach)], :);
    out = weights(1) * p(1:height, :);
    for k = 2:numel(weights)
        out = out + weights(k) * p(k:height + k - 1, :);
    end
    p = out(:, [ones(1, reach), 1:width, width * ones(1, reach)]);
    out = weights(1) * p(:, 1:width);
    for k = 2:numel(weights)
        out = out + weights(k) * p(:, k:width + k - 1);
    end
    image = out;
end

function image = saturated(image)
    % dev's imadjustn and im2uint8: the finite values sorted, the low limit the first whose share of the values at or below
    % it is over 1% (floor(0.01 n) + 1) and the high one the first at 99% (ceil(0.99 n)); values beyond them cut to them and
    % the rest stretched to 0..255, floor(v + 0.5). NaN stays NaN; a flat image is 0
    values = sort(image(isfinite(image)));
    count = numel(values);
    if count == 0
        return
    end
    low = values(floor(0.01 * count) + 1);
    high = values(ceil(0.99 * count));
    if ~(high > low)
        flat = zeros(size(image));
        flat(isnan(image)) = NaN;
        image = flat;
        return
    end
    cut = image;
    cut(image < low) = low;
    cut(image > high) = high;
    image = floor((cut - low) / (high - low) * 255 + 0.5);
end
