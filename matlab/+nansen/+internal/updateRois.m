function [document, added] = updateRois(document, classify, remove, add, move, merge)
%updateRois The ROI file with ROIs classified, moved, merged, removed and added, as Python's nansen.frames.update_rois
%
%   classify is a struct array of id and classification (accepted,
%   rejected, or [] for none); move a struct array of id, rows and columns
%   (whole-pixel shifts; pixels leaving the image are left out); merge a
%   list of id lists (the first ROI of each takes the pixels of all and
%   keeps its id and classification, the others are removed); remove a
%   list of ids; add a struct array of pixels ([row, column], 0-based). An
%   added ROI gets the next free id. A changed or added ROI gets its area
%   and center again; pixels outside imageSize are left out. added are the
%   ids of the added ROIs. ROIs come back with their pixels as lists of
%   pairs, so they are written as the file had them.
    if nargin < 5
        move = [];
    end
    if nargin < 6
        merge = [];
    end
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
    size_ = [];
    if isfield(document, "imageSize")
        size_ = reshape(double(document.imageSize), 1, []);
    end

    for change = asStructs(classify, ["id", "classification"])
        match = find_(ids, nansen.internal.getField(change, "id", NaN));
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
    for change = asStructs(move, ["id", "rows", "columns"])
        match = find_(ids, nansen.internal.getField(change, "id", NaN));
        shift = [double(nansen.internal.getField(change, "rows", 0)), double(nansen.internal.getField(change, "columns", 0))];
        rois{match} = measure(rois{match}, inside(rois{match}.pixels + shift, size_));
    end
    gone = [];
    if isnumeric(merge) && ~isempty(merge)
        merge = num2cell(merge, 2);   % one group, decoded as a matrix
    end
    for g = 1:numel(merge)
        group = double(merge{g}(:))';
        if numel(group) < 2 || numel(unique(group)) ~= numel(group)
            nansen.internal.throwError("invalid-params", "a merge is a list of two or more different ROI ids")
        end
        first = find_(ids, group(1));
        pixels = rois{first}.pixels;
        for id = group(2:end)
            pixels = [pixels; rois{find_(ids, id)}.pixels]; %#ok<AGROW>
            gone(end + 1) = id; %#ok<AGROW>
        end
        rois{first} = measure(rois{first}, pixels);
    end
    remove = double(remove(:))';
    for id = remove
        find_(ids, id);
    end
    rois = rois(~ismember(ids, [gone, remove]));
    nextId = max([ids, 0]) + 1;
    added = {};
    if iscell(add)
        add = [add{:}];
    end
    for new = reshape(add, 1, [])
        pixels = inside(round(nansen.internal.roiPixels(new)), size_);
        if isempty(pixels)
            nansen.internal.throwError("invalid-params", "an added ROI needs pixels inside the image")
        end
        rois{end + 1} = measure(struct("id", nextId), pixels); %#ok<AGROW>
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

function match = find_(ids, id)
    match = find(ids == id, 1);
    if isempty(match)
        nansen.internal.throwError("invalid-params", "there is no ROI %s", jsonencode(id))
    end
end

function pixels = inside(pixels, size_)
    if ~isempty(size_)
        pixels = pixels(pixels(:, 1) >= 0 & pixels(:, 1) < size_(1) & pixels(:, 2) >= 0 & pixels(:, 2) < size_(2), :);
    end
end

function roi = measure(roi, pixels)
    pixels = unique(pixels, "rows");
    if isempty(pixels)
        nansen.internal.throwError("invalid-params", "ROI %g would have no pixels inside the image", roi.id)
    end
    roi.area = size(pixels, 1);
    roi.center = floor([mean(pixels(:, 1)), mean(pixels(:, 2))] * 100 + 0.5) / 100;
    roi.pixels = pixels;
end

function out = asStructs(value, ~)
    if isempty(value)
        out = struct("id", {});
    elseif iscell(value)
        out = [value{:}];
    else
        out = reshape(value, 1, []);
    end
end
