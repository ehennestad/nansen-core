function [document, added] = importRoisAt(document, plane, channel, source, mode, firstId)
%importRoisAt Combine the ROIs of another ROI file into a file's ROIs at a plane and channel (from 1)
%
%   As roimanager adds loaded ROIs to those it has. The source's ROIs at
%   that place (all of them when it has no places) are taken, with their
%   pixels outside the file's imageSize (or the source's, when the file has
%   none) left out, and those with none inside left out altogether. mode is
%   "replace" (the place's ROIs are removed first), "append", or
%   "appendNonOverlapping" (a source ROI that overlaps one of the place's
%   ROIs, as nansen.internal.roisOverlap finds, is left out). The place's
%   ROIs that stay keep everything; the imported ones get the next free
%   ids, in the source's order, as updateRois adds ROIs, and keep their
%   classification, cell type, tags, uid (unless an ROI of the file has it
%   already) and their links among themselves. added are their ids (from
%   firstId on at least, when given). As Python's nansen.frames.import_rois_at.
    if nargin < 6
        firstId = 1;
    end
    mode = string(mode);
    if ~(isscalar(mode) && any(mode == ["replace", "append", "appendNonOverlapping"]))
        nansen.internal.throwError("invalid-params", "an import's mode is replace, append or appendNonOverlapping, not '%s'", strjoin(mode, ""))
    end
    nansen.internal.roiOutlines(source);   % checks the shape
    if ~isfield(document, "imageSize") && isfield(source, "imageSize") && ~isempty(source.imageSize)
        document.imageSize = reshape(double(source.imageSize), 1, []);
    end
    size_ = [];
    if isfield(document, "imageSize") && ~isempty(document.imageSize)
        size_ = reshape(double(document.imageSize), 1, []);
    end

    rois = cellsOf(source);
    for i = 1:numel(rois)
        rois{i}.id = double(nansen.internal.getField(rois{i}, "id", i));
    end
    numbered = source;
    numbered.rois = rois;
    placed = cellsOf(nansen.internal.roisAt(numbered, plane, channel));
    incoming = {};   % the source's ROIs taken
    pixelsIn = {};   % and their pixels inside the image
    for i = 1:numel(placed)
        pixels = round(nansen.internal.roiPixels(placed{i}));
        if ~isempty(size_)
            pixels = pixels(pixels(:, 1) >= 0 & pixels(:, 1) < size_(1) & pixels(:, 2) >= 0 & pixels(:, 2) < size_(2), :);
        end
        pixels = unique(pixels, "rows");
        if ~isempty(pixels)
            incoming{end + 1} = placed{i}; %#ok<AGROW>
            pixelsIn{end + 1} = pixels; %#ok<AGROW>
        end
    end

    here = nansen.internal.roiOutlines(nansen.internal.roisAt(document, plane, channel));
    remove = zeros(1, 0);
    if mode == "replace"
        for j = 1:numel(here)
            remove(end + 1) = double(here{j}.id); %#ok<AGROW>
        end
    end
    if mode == "appendNonOverlapping"
        keep = true(1, numel(incoming));
        for i = 1:numel(incoming)
            for j = 1:numel(here)
                if nansen.internal.roisOverlap(pixelsIn{i}, nansen.internal.roiPixels(here{j}))
                    keep(i) = false;
                    break
                end
            end
        end
        incoming = incoming(keep);
        pixelsIn = pixelsIn(keep);
    end
    add = cell(1, numel(pixelsIn));
    for i = 1:numel(pixelsIn)
        add{i} = struct("pixels", pixelsIn{i});
    end
    [document, added] = nansen.internal.updateRoisAt(document, plane, channel, [], remove, add, [], [], [], missing, [], [], firstId);

    addedIds = zeros(1, numel(added));
    for i = 1:numel(added)
        addedIds(i) = double(added{i});
    end
    rois = cellsOf(document);
    ids = zeros(1, numel(rois));
    taken = strings(1, 0);   % the uids of the ROIs the file had
    for i = 1:numel(rois)
        ids(i) = double(rois{i}.id);
        if ~ismember(ids(i), addedIds) && isfield(rois{i}, "uid") && ~isempty(rois{i}.uid)
            taken(end + 1) = string(rois{i}.uid); %#ok<AGROW>
        end
    end
    sourceIds = zeros(1, numel(incoming));
    for i = 1:numel(incoming)
        sourceIds(i) = double(incoming{i}.id);
    end
    for i = 1:numel(incoming)
        roi = incoming{i};
        at = find(ids == addedIds(i), 1);
        target = rois{at};
        label = nansen.internal.getField(roi, "classification", []);
        if ~isempty(label) && (ischar(label) || isstring(label)) && any(string(label) == ["accepted", "rejected", "unresolved"])
            target.classification = char(label);
        end
        for name = ["cellType", "tags"]
            if isfield(roi, name) && ~isempty(roi.(name))
                target.(name) = roi.(name);
            end
        end
        uid = nansen.internal.getField(roi, "uid", []);
        if ~isempty(uid) && ~ismember(string(uid), taken)
            target.uid = char(uid);
            taken(end + 1) = string(uid); %#ok<AGROW>
        end
        links = linksOf(roi);
        links = links(ismember(links, sourceIds));
        if ~isempty(links)
            mapped = zeros(1, numel(links));
            for k = 1:numel(links)
                mapped(k) = addedIds(find(sourceIds == links(k), 1));
            end
            target.links = num2cell(sort(mapped));   % a list, also of one
        end
        rois{at} = target;
    end
    document.rois = rois;
end

function rois = cellsOf(value)
    % The ROIs of an ROI file as a 1 x n cell, however jsondecode gave them
    rois = {};
    if isstruct(value) && isfield(value, "rois") && ~isempty(value.rois)
        rois = value.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
        rois = reshape(rois, 1, []);
    end
end

function list = linksOf(roi)
    % The ids an ROI is linked with, as a row (a JSON list decodes as an array, or a cell)
    list = zeros(1, 0);
    if isfield(roi, "links") && ~isempty(roi.links)
        list = roi.links;
        if iscell(list)
            list = cell2mat(cellfun(@double, list(:)', UniformOutput=false));
        end
        list = double(reshape(list, 1, []));
    end
end
