function pixels = weightsPixels(weights, threshold)
%weightsPixels The 8-connected area around a spatial footprint's peak of pixels weighing at least threshold x the
%peak's, as 0-based [row, column] pixels; the first peak in row-major order when several are equal. As Python's
%ophys_adapters.weights_pixels.
    if nargin < 2
        threshold = 0.2;
    end
    weights = double(weights);
    pixels = zeros(0, 2);
    if isempty(weights) || max(weights, [], "all") <= 0
        return
    end
    [~, at] = max(reshape(weights.', 1, []));   % row-major
    [column, row] = ind2sub([size(weights, 2), size(weights, 1)], at);
    areas = ophys.internal.components(weights >= threshold * weights(row, column), 8);
    for k = 1:numel(areas)
        if any(areas{k}(:, 1) == row & areas{k}(:, 2) == column)
            pixels = areas{k} - 1;
            return
        end
    end
end
