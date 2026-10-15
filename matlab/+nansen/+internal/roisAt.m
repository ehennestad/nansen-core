function value = roisAt(value, plane, channel)
%roisAt The ROI file with the ROIs of a plane and channel (from 1) only, and those with no place
%
%   All of them when none has a place (a plane and channel, as dev's RoiGroup
%   of several gives). As Python's nansen.frames.rois_at.
    rois = roiCells(value);
    if ~any(cellfun(@hasPlace, rois))
        return
    end
    keep = cellfun(@(r) nansen.internal.getField(r, "plane", plane) == plane && ...
        nansen.internal.getField(r, "channel", channel) == channel, rois);
    value.rois = rois(keep);
end

function yes = hasPlace(roi)
    yes = isstruct(roi) && (isfield(roi, "plane") || isfield(roi, "channel"));
end

function rois = roiCells(value)
    rois = {};
    if isstruct(value) && isfield(value, "rois") && ~isempty(value.rois)
        rois = value.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
        rois = reshape(rois, 1, []);
    end
end
