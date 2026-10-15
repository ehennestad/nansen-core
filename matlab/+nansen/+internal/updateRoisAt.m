function [document, added] = updateRoisAt(document, plane, channel, classify, remove, add, move, merge, pixelChanges, restore, cellTypes, links)
%updateRoisAt updateRois on the ROIs of a plane and channel (from 1) of a file whose ROIs have places
%
%   A restore puts back that place's ROIs only, and added ROIs are put
%   there. A file whose ROIs have no places is updated as by updateRois.
%   As Python's nansen.frames.update_rois_at.
    if nargin < 11
        cellTypes = [];
    end
    if nargin < 12
        links = [];
    end
    rois = {};
    if isstruct(document) && isfield(document, "rois") && ~isempty(document.rois)
        rois = document.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
        rois = reshape(rois, 1, []);
    end
    if ~any(cellfun(@(r) isstruct(r) && (isfield(r, "plane") || isfield(r, "channel")), rois))
        [document, added] = nansen.internal.updateRois(document, classify, remove, add, move, merge, pixelChanges, restore, cellTypes, links);
        return
    end
    places = zeros(0, 3);   % id, plane, channel
    elsewhere = {};
    for i = 1:numel(rois)
        rois{i}.id = nansen.internal.getField(rois{i}, "id", i);
        if isfield(rois{i}, "plane")
            places(end + 1, :) = [rois{i}.id, rois{i}.plane, nansen.internal.getField(rois{i}, "channel", 1)]; %#ok<AGROW>
        end
        if nansen.internal.getField(rois{i}, "plane", plane) ~= plane || nansen.internal.getField(rois{i}, "channel", channel) ~= channel
            elsewhere{end + 1} = rois{i}; %#ok<AGROW>
        end
    end
    document.rois = rois;
    if ~isa(restore, "missing")   % the others stay as they are
        if isstruct(restore)
            restore = num2cell(restore);
        elseif isempty(restore)
            restore = {};
        end
        restore = [elsewhere, reshape(restore, 1, [])];
    end
    [document, added] = nansen.internal.updateRois(document, classify, remove, add, move, merge, pixelChanges, restore, cellTypes, links);
    rois = document.rois;
    if isstruct(rois)
        rois = num2cell(rois);
    end
    for i = 1:numel(rois)
        if ~isfield(rois{i}, "plane")
            row = find(places(:, 1) == rois{i}.id, 1);
            if isempty(row)
                rois{i}.plane = plane;
                rois{i}.channel = channel;
            else
                rois{i}.plane = places(row, 2);
                rois{i}.channel = places(row, 3);
            end
        end
    end
    document.rois = reshape(rois, 1, []);
end
