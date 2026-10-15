function [pixels, slices] = roiNeuropil(value, roi, options, height, width)
%roiNeuropil The neuropil pixels of an ROI of an ROI file, as ophys.extractSignals takes them
%
%   An N-by-2 matrix of [row, column] (0-based, row-major) of the neuropil
%   of the ROI of id roi (nansen.internal.neuropilMasks): among the file's
%   ROIs, less those rejected unless options.includeRejected, and the ROI
%   itself always. Pixels outside the height x width image are left out.
%   slices is the slice (from 1) of each pixel (nansen.internal.neuropilSlices,
%   options.numNeuropilSlices; all 1 with one slice). As Python's
%   nansen.frames.roi_neuropil.
    rois = nansen.internal.roiOutlines(value);
    at = 0;
    for i = 1:numel(rois)
        if isequal(double(rois{i}.id), double(roi))
            at = i;
            break
        end
    end
    if at == 0
        nansen.internal.throwError("invalid-params", "there is no ROI %s", strjoin(string(roi), ", "))
    end
    includeRejected = isequal(nansen.internal.getField(options, "includeRejected", false), true);
    masks = {};
    own = 0;
    for i = 1:numel(rois)
        classification = rois{i}.classification;
        rejected = (ischar(classification) || isstring(classification)) && string(classification) == "rejected";
        if i ~= at && rejected && ~includeRejected
            continue
        end
        points = nansen.internal.roiPixels(rois{i});
        inside = points(:, 1) >= 0 & points(:, 1) < height & points(:, 2) >= 0 & points(:, 2) < width;
        mask = false(height, width);
        mask(sub2ind([height, width], points(inside, 1) + 1, points(inside, 2) + 1)) = true;
        masks{end + 1} = mask; %#ok<AGROW>
        if i == at
            own = numel(masks);
        end
    end
    neuropil = nansen.internal.neuropilMasks(masks, options, own);
    parts = nansen.internal.neuropilSlices(neuropil{1}, masks{own}, double(nansen.internal.getField(options, "numNeuropilSlices", 1)));
    labels = zeros(height, width);
    for k = 1:numel(parts)
        labels(parts{k}) = k;
    end
    [rows, columns] = find(neuropil{1});
    [pixels, order] = sortrows([rows, columns] - 1);
    slices = labels(sub2ind([height, width], rows(order), columns(order)));
end
