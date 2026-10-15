function mask = roiMask(image, center, diameter)
%roiMask The ROI in a window of +-15 px around the (0-based) center, as Python's roi_mask
%
%   Above the mid-point of the window's 50th and 95th percentile, without
%   bits under a tenth of a cell's area, holes filled, the (first) largest area.
    [height, width] = size(image);
    cy = floor(center(1) + 0.5);
    cx = floor(center(2) + 0.5);
    w = min([15, cy, height - 1 - cy, cx, width - 1 - cx]);
    window = image(cy - w + 1:cy + w + 1, cx - w + 1:cx + w + 1);
    low = ophys.internal.percentileOf(window(:), 50);
    high = ophys.internal.percentileOf(window(:), 95);
    bw = window > low + (high - low) / 2;
    smallest = floor(pi * (diameter / 2) ^ 2 / 10 + 0.5);
    pieces = ophys.internal.components(bw, 8);
    bw = false(size(bw));
    for i = 1:numel(pieces)
        if size(pieces{i}, 1) >= smallest
            bw(sub2ind(size(bw), pieces{i}(:, 1), pieces{i}(:, 2))) = true;
        end
    end
    pieces = ophys.internal.components(ophys.internal.fillHoles(bw), 8);
    mask = false(height, width);
    if ~isempty(pieces)
        [~, largest] = max(cellfun(@(p) size(p, 1), pieces));   % the first of the largest
        pixels = pieces{largest};
        mask(sub2ind([height, width], cy - w + pixels(:, 1), cx - w + pixels(:, 2))) = true;
    end
end
