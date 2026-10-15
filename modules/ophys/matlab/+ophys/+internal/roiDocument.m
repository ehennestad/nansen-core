function document = roiDocument(imageSize, pixelLists, classifications, places)
%roiDocument The module's ROI document of ROIs given as 0-based [row, column] pixels, in file order
%
%   ids from 1, pixels outside the image left out and the rest in row-major
%   order, area, and center the mean row and column rounded to 2 decimals;
%   classification where classifications{k} is not ""; and with places (a
%   row of [plane, channel] per ROI, from 1), plane and channel. Python's
%   ophys_adapters.roi_document makes the same.
    height = double(imageSize(1));
    width = double(imageSize(2));
    if nargin < 3
        classifications = repmat({""}, 1, numel(pixelLists));
    end
    rois = cell(1, numel(pixelLists));
    for k = 1:numel(pixelLists)
        pixels = double(reshape(pixelLists{k}, [], 2));
        inside = pixels(:, 1) >= 0 & pixels(:, 1) < height & pixels(:, 2) >= 0 & pixels(:, 2) < width;
        pixels = unique(pixels(inside, :), "rows");   % sorted: row-major
        roi = struct("id", k, "area", size(pixels, 1), ...
            "center", [ophys.internal.roundTo(mean(pixels(:, 1)), 2), ophys.internal.roundTo(mean(pixels(:, 2)), 2)], ...
            "pixels", {num2cell(pixels, 2)'});
        if strlength(string(classifications{k})) > 0
            roi.classification = char(classifications{k});
        end
        if nargin >= 4
            roi.plane = places(k, 1);
            roi.channel = places(k, 2);
        end
        rois{k} = roi;
    end
    document = struct("imageSize", [height, width], "rois", {rois});
end
