function [document, summary] = mirrorRoisAt(document, plane, channel, before, after, source, target, size_)
%mirrorRoisAt An aligned entity's ROI file with an edit of another's ROIs made to it too, at the same plane and channel
%
%   As dev's synchEntries mirrors: rois.update's mirror. target and source
%   are the two entities' entries of the alignment; before and after the
%   edited entity's ROIs at the plane and channel (from 1), as
%   nansen.internal.roiOutlines gives them, before and after the edit;
%   size_ the aligned images' [height, width]. summary has the ids added,
%   changed and removed here.
%
%   An ROI the edit removed is removed here. An ROI it added or whose
%   pixels it changed gets its pixels carried here
%   (nansen.internal.carriedPixels): an ROI of that id here takes them (and
%   is removed when none land inside the image); otherwise it is added with
%   that id, its classification and cell type, unless no pixel lands inside
%   or an ROI of another plane or channel has the id. A classification or
%   cell type the edit changed is set here too. As Python's
%   nansen.frames.mirror_rois_at.
    height = double(size_(1));
    width = double(size_(2));
    oldIds = idsOf(before);
    newIds = idsOf(after);
    reshaped = zeros(1, 0);
    for id = sort(newIds)
        k = find(newIds == id, 1);
        j = find(oldIds == id, 1);
        if isempty(j) || ~isequal(sortrows(nansen.internal.roiPixels(after{k})), sortrows(nansen.internal.roiPixels(before{j})))
            reshaped(end + 1) = id; %#ok<AGROW>
        end
    end
    here = idsOf(nansen.internal.roiOutlines(nansen.internal.roisAt(document, plane, channel)));
    everywhere = idsOf(nansen.internal.roiOutlines(document));
    remove = sort(oldIds(~ismember(oldIds, newIds) & ismember(oldIds, here)));
    remove = reshape(remove, 1, []);
    pixelChanges = {};
    add = {};
    wanted = zeros(1, 0);
    for id = reshaped
        pixels = nansen.internal.carriedPixels(nansen.internal.roiPixels(after{find(newIds == id, 1)}), source, target, height, width);
        if ismember(id, here)
            if ~isempty(pixels)
                pixelChanges{end + 1} = struct("id", id, "pixels", pixels); %#ok<AGROW>
            else
                remove(end + 1) = id; %#ok<AGROW>
            end
        elseif ~isempty(pixels) && ~ismember(id, everywhere)
            add{end + 1} = struct("pixels", pixels); %#ok<AGROW>
            wanted(end + 1) = id; %#ok<AGROW>
        end
    end
    classify = {};
    cellTypes = {};
    for id = sort(newIds)
        j = find(oldIds == id, 1);
        if isempty(j) || ~ismember(id, here) || ismember(id, remove)
            continue
        end
        k = find(newIds == id, 1);
        if labelOf(after{k}, "classification") ~= labelOf(before{j}, "classification")
            classify{end + 1} = struct("id", id, "classification", valueOf(after{k}, "classification")); %#ok<AGROW>
        end
        if labelOf(after{k}, "cellType") ~= labelOf(before{j}, "cellType")
            cellTypes{end + 1} = struct("id", id, "cellType", valueOf(after{k}, "cellType")); %#ok<AGROW>
        end
    end
    [document, got] = nansen.internal.updateRoisAt(document, plane, channel, classify, sort(remove), add, [], [], ...
        pixelChanges, missing, cellTypes, []);
    gotIds = zeros(1, numel(got));
    for i = 1:numel(got)
        gotIds(i) = double(got{i});
    end
    used = false(1, numel(gotIds));
    rois = document.rois;
    if isstruct(rois)
        rois = num2cell(rois);
    end
    for i = 1:numel(rois)
        at = find(gotIds == double(rois{i}.id) & ~used, 1);
        if isempty(at)
            continue
        end
        % an added ROI takes the id it has in the entity edited, and its classification and cell type
        used(at) = true;
        id = wanted(at);
        rois{i}.id = id;
        source_ = after{find(newIds == id, 1)};
        label = valueOf(source_, "classification");
        if ~isempty(label) && any(string(label) == ["accepted", "rejected", "unresolved"])
            rois{i}.classification = char(label);
        end
        type = valueOf(source_, "cellType");
        if ~isempty(type)
            rois{i}.cellType = char(type);
        end
    end
    document.rois = rois;
    changed = zeros(1, 0);
    for i = 1:numel(pixelChanges)
        changed(end + 1) = pixelChanges{i}.id; %#ok<AGROW>
    end
    for i = 1:numel(classify)
        changed(end + 1) = classify{i}.id; %#ok<AGROW>
    end
    for i = 1:numel(cellTypes)
        changed(end + 1) = cellTypes{i}.id; %#ok<AGROW>
    end
    summary = struct("added", {num2cell(sort(wanted))}, "changed", {num2cell(unique(changed))}, ...
        "removed", {num2cell(sort(remove))});
end

function ids = idsOf(outlines)
    % The ids of ROIs as roiOutlines gives them, as a row
    ids = zeros(1, numel(outlines));
    for i = 1:numel(outlines)
        ids(i) = double(outlines{i}.id);
    end
end

function text = labelOf(roi, name)
    % An ROI's classification or cell type as text, "" for none
    value = valueOf(roi, name);
    if isempty(value)
        text = "";
    else
        text = string(value);
    end
end

function value = valueOf(roi, name)
    % An ROI's classification or cell type, [] for none
    value = nansen.internal.getField(roi, name, []);
    if isstring(value) && value == ""
        value = [];
    elseif ischar(value) && isempty(value)
        value = [];
    end
end
