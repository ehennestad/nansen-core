function [document, added] = updateRois(document, classify, remove, add)
%updateRois The ROI file with ROIs classified, removed and added, as Python's nansen.frames.update_rois
%
%   classify is a struct array of id and classification (accepted,
%   rejected, or [] for none); remove a list of ids; add a struct array of
%   pixels ([row, column], 0-based). An added ROI gets the next free id,
%   its area and its center; pixels outside imageSize are left out.
%   added are the ids of the added ROIs. ROIs come back with their pixels
%   as lists of pairs, so they are written as the file had them.
    nansen.internal.roiOutlines(document);   % checks the shape
    rois = {};
    if isfield(document, "rois") && ~isempty(document.rois)
        rois = document.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
    end
    rois = reshape(rois, 1, []);
    ids = zeros(1, numel(rois));
    for i = 1:numel(rois)
        rois{i}.id = nansen.internal.getField(rois{i}, "id", i);
        rois{i}.pixels = nansen.internal.roiPixels(rois{i});
        ids(i) = rois{i}.id;
    end
    if isempty(classify)
        classify = struct("id", {}, "classification", {});
    elseif iscell(classify)
        classify = [classify{:}];
    end
    for change = reshape(classify, 1, [])
        match = find(ids == nansen.internal.getField(change, "id", NaN), 1);
        if isempty(match)
            nansen.internal.throwError("invalid-params", "there is no ROI %s", jsonencode(nansen.internal.getField(change, "id", [])))
        end
        label = nansen.internal.getField(change, "classification", []);
        if isempty(label)
            if isfield(rois{match}, "classification")
                rois{match} = rmfield(rois{match}, "classification");
            end
        elseif any(string(label) == ["accepted", "rejected"])
            rois{match}.classification = char(label);
        else
            nansen.internal.throwError("invalid-params", "an ROI is accepted or rejected, not '%s'", string(label))
        end
    end
    remove = double(remove(:))';
    for id = remove
        if ~any(ids == id)
            nansen.internal.throwError("invalid-params", "there is no ROI %g", id)
        end
    end
    rois = rois(~ismember(ids, remove));
    size_ = [];
    if isfield(document, "imageSize")
        size_ = reshape(double(document.imageSize), 1, []);
    end
    nextId = max([ids, 0]) + 1;
    added = {};
    if iscell(add)
        add = [add{:}];
    end
    for new = reshape(add, 1, [])
        pixels = round(nansen.internal.roiPixels(new));
        if ~isempty(size_)
            pixels = pixels(pixels(:, 1) >= 0 & pixels(:, 1) < size_(1) & pixels(:, 2) >= 0 & pixels(:, 2) < size_(2), :);
        end
        pixels = unique(pixels, "rows");
        if isempty(pixels)
            nansen.internal.throwError("invalid-params", "an added ROI needs pixels inside the image")
        end
        roi = struct("id", nextId, "area", size(pixels, 1), ...
            "center", floor([mean(pixels(:, 1)), mean(pixels(:, 2))] * 100 + 0.5) / 100, "pixels", pixels);
        rois{end + 1} = roi; %#ok<AGROW>
        added{end + 1} = nextId; %#ok<AGROW>
        nextId = nextId + 1;
    end
    for i = 1:numel(rois)
        rois{i}.pixels = num2cell(rois{i}.pixels, 2)';
    end
    document.rois = rois;
    if ~isempty(size_)
        document.imageSize = size_;
    end
end
