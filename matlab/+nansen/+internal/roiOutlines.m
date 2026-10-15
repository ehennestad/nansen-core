function out = roiOutlines(value)
%roiOutlines The ROIs of an ROI file ({rois: [{id?, pixels: [[row, column], ...]}]}, 0-based) as the viewer draws them
%
%   A cell array of structs with id, pixels (a list of [row, column]
%   pairs) and classification, as Python's nansen.frames.roi_outlines gives.
    if ~isstruct(value) || ~isscalar(value)
        nansen.internal.throwError("invalid-data", "the ROIs are not a JSON object with a list of rois")
    end
    rois = {};
    if isfield(value, "rois") && ~isempty(value.rois)
        rois = value.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        elseif ~iscell(rois)
            nansen.internal.throwError("invalid-data", "the ROIs are not a JSON object with a list of rois")
        end
    end
    out = cell(1, numel(rois));
    for i = 1:numel(rois)
        out{i} = struct("id", nansen.internal.getField(rois{i}, "id", i), ...
            "pixels", {num2cell(nansen.internal.roiPixels(rois{i}), 2)'}, ...
            "classification", nansen.internal.getField(rois{i}, "classification", []));
    end
end
