function result = alignSessions(entities, options, context)
%alignSessions Align each entity's FOV image to the first entity's, and copy the first entity's ROIs, moved, to the others
%
%   With maxRotation, each image is also turned back by each angle from
%   -maxRotation to maxRotation in steps of rotationStep, and the angle of
%   largest correlation (the smallest, then the negative, of equal ones) is
%   taken. With patches > 1, the image moved back by that shift and turned
%   back by that angle is cut into patches x patches patches, as the motion
%   correction's, and each finds its own whole-pixel shift within
%   maxDeviation of none (piecewise rigid, dev's alignFovs' non-rigid step);
%   the displacement field d interpolates them bilinearly between the patch
%   centres. An ROI pixel p of the first entity goes to rotation(angle) *
%   (p + d(p) + shift - centre) + centre, rounded half up
%   (nansen.internal.alignedPoints).
%
%   Every entity's ROI file keeps the alignment ({reference, imageSize,
%   entities: [{key, variable, shift, rotation, patches, rowShifts,
%   columnShifts}]}), so rois.update can mirror an edit to the others. With
%   existingRois keepCuration (the default), an entity that has ROIs
%   already keeps, for the ROIs of the ids the copies have, their
%   classification, cell type, tags, uid and links, and keeps its ROIs of
%   ids the first entity does not have; with replace, the copies replace
%   them. As Python's ophys_methods.align_sessions.
    if isempty(entities)
        nansen.internal.throwError("no-entities", "no entities to align")
    end
    reference = ophys.internal.fovImage(context.Project.load(entities{1}, options.image));
    [height, width] = size(reference);
    most = double(nansen.internal.getField(options, "maxRotation", 0));
    step = double(nansen.internal.getField(options, "rotationStep", 0.5));
    if most > 0 && step <= 0
        nansen.internal.throwError("invalid-options", "rotationStep is more than 0")
    end
    patches = double(nansen.internal.getField(options, "patches", 1));
    deviation = double(nansen.internal.getField(options, "maxDeviation", 3));
    if patches < 1 || (patches > 1 && (floor(height / patches) < 4 || floor(width / patches) < 4))
        nansen.internal.throwError("invalid-options", "%d x %d patches of a %d x %d image are not 1, or smaller than 4 pixels", ...
            patches, patches, height, width)
    end
    existing = string(nansen.internal.getField(options, "existingRois", "keepCuration"));
    if ~(isscalar(existing) && any(existing == ["keepCuration", "replace"]))
        nansen.internal.throwError("invalid-options", "existingRois is keepCuration or replace, not '%s'", strjoin(existing, ""))
    end
    count = 0;
    if most > 0
        count = floor(most / step + 1e-9);
    end
    angles = (-count:count) * step;
    [~, order] = sortrows([abs(angles(:)), angles(:)]);
    angles = angles(order);
    tapered = most > 0;
    referenceFft = ophys.internal.referenceFft(reference, tapered);
    rows = ophys.internal.shiftRange(0, options.maxShift, options.maxShift, floor((height - 1) / 2));
    columns = ophys.internal.shiftRange(0, options.maxShift, options.maxShift, floor((width - 1) / 2));
    rowEdges = ophys.internal.patchEdges(height, patches);
    columnEdges = ophys.internal.patchEdges(width, patches);
    patchFfts = cell(patches, patches);
    if patches > 1
        for i = 1:patches
            for j = 1:patches
                patchFfts{i, j} = ophys.internal.referenceFft(reference(rowEdges(i) + 1:rowEdges(i + 1), columnEdges(j) + 1:columnEdges(j + 1)), true);
            end
        end
    end
    document = context.Project.load(entities{1}, options.rois);
    numbered = ophys.internal.roiList(document);
    referenceIds = zeros(1, numel(numbered));
    for i = 1:numel(numbered)
        numbered{i}.id = double(nansen.internal.getField(numbered{i}, "id", i));
        referenceIds(i) = numbered{i}.id;
    end
    keep = cellfun(@(r) ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), numbered);
    rois = numbered(keep);
    shifts = cell(1, numel(entities));
    entries = cell(1, numel(entities));
    for number = 1:numel(entities)
        context.checkCancelled();
        entity = entities{number};
        image = ophys.internal.fovImage(context.Project.load(entity, options.image));
        if ~isequal(size(image), [height, width])
            nansen.internal.throwError("invalid-data", "%s: the image is %s, the reference %s", ...
                ophys.internal.entityName(entity), mat2str(size(image)), mat2str([height, width]))
        end
        best = -Inf;
        for angle = angles
            turned = image;
            if angle ~= 0
                turned = ophys.internal.rotateImage(image, angle);
            end
            if tapered
                turned = ophys.internal.tapered(turned);
            end
            correlation = ophys.internal.correlation(turned, referenceFft);
            [dy, dx] = ophys.internal.peak(correlation, [], rows, columns, false);
            value = correlation(mod(dy, height) + 1, mod(dx, width) + 1);
            if value > best
                best = value;
                shift = [dy, dx];
                rotation = angle;
            end
        end
        entry = struct("key", entity.Key, "shift", shift, "rotation", rotation);
        if patches > 1   % the rest, piecewise: the patches of the image moved and turned back, against the reference's
            registered = ophys.internal.transformImage(image, shift, rotation);
            found = ophys.internal.estimatePatchShifts(registered, patchFfts, rowEdges, columnEdges, [0, 0], ...
                options.maxShift, deviation, false);
            entry.patches = patches;   % patch (i, j) (from 0) at i * patches + j in the lists
            entry.rowShifts = reshape(reshape(found(1, 1, :, :), patches, patches).', 1, []);
            entry.columnShifts = reshape(reshape(found(1, 2, :, :), patches, patches).', 1, []);
        end
        shifts{number} = entry;
        if number == 1
            entry.variable = char(options.rois);
        else
            entry.variable = char(options.output);
        end
        entries{number} = entry;
        context.progress(number / numel(entities), ophys.internal.entityName(entity));
    end
    alignment = struct("reference", entities{1}.Key, "imageSize", [height, width], "entities", {entries});
    kept = 0;
    for number = 2:numel(entities)
        context.checkCancelled();
        entity = entities{number};
        moved = {};
        for i = 1:numel(rois)
            points = floor(nansen.internal.alignedPoints(rois{i}.pixels, entries{number}, height, width) + 0.5);
            points = unique(points(points(:, 1) >= 0 & points(:, 1) < height & points(:, 2) >= 0 & points(:, 2) < width, :), "rows");
            if ~isempty(points)
                moved{end + 1} = ophys.internal.makeRoi(rois{i}.id, points + 1); %#ok<AGROW>
            end
        end
        if existing == "keepCuration"
            [moved, curated] = keepCuration(moved, existingRois(entity, options.output, context), referenceIds);
            kept = kept + curated;
        end
        context.Project.save(entity, options.output, struct("imageSize", [height, width], "rois", {moved}, "alignment", alignment));
    end
    % the reference's ROI file keeps the alignment too (its ROIs as they are, their pixels as lists of pairs)
    references = {};
    if isfield(document, "rois") && ~isempty(document.rois)
        references = document.rois;
        if isstruct(references)
            references = num2cell(references);
        end
        references = reshape(references, 1, []);
    end
    for i = 1:numel(references)
        references{i}.pixels = num2cell(nansen.internal.roiPixels(references{i}), 2)';
    end
    document.rois = references;
    document.alignment = alignment;
    context.Project.save(entities{1}, options.rois, document);
    context.log("aligned %d entities to %s", numel(entities), ophys.internal.entityName(entities{1}));
    result = struct("reference", entities{1}.Key, "shifts", {shifts}, "migrated", numel(entities) - 1, "rois", numel(rois), "kept", kept);
end

function rois = existingRois(entity, name, context)
    % The ROIs an entity has in a variable already (its ROI file's, numbered, their pixels as lists of pairs), or none
    % when it has no file of it
    rois = {};
    try
        document = context.Project.load(entity, name, Cached=false);
    catch err
        if ismember(err.identifier, ["nansen:DataNotFound", "nansen:UnknownDataVariable"])
            return
        end
        rethrow(err)
    end
    if isstruct(document) && isfield(document, "rois") && ~isempty(document.rois)
        rois = document.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
        rois = reshape(rois, 1, []);
    end
    for i = 1:numel(rois)
        rois{i}.id = double(nansen.internal.getField(rois{i}, "id", i));
        rois{i}.pixels = num2cell(nansen.internal.roiPixels(rois{i}), 2)';
    end
end

function [rois, curated] = keepCuration(moved, existing, referenceIds)
    % The copied ROIs with the curation of the entity's own ROIs of the same ids (classification, cell type, tags, uid
    % and links), followed by its ROIs of ids the reference does not have, as they are; links only to ROIs there
    existingIds = zeros(1, numel(existing));
    for i = 1:numel(existing)
        existingIds(i) = existing{i}.id;
    end
    curated = 0;
    for i = 1:numel(moved)
        at = find(existingIds == double(moved{i}.id), 1);
        if isempty(at)
            continue
        end
        took = false;
        for name = ["classification", "cellType", "tags", "uid", "links"]
            if isfield(existing{at}, name) && ~isNone(existing{at}.(name))
                moved{i}.(name) = existing{at}.(name);
                took = true;
            end
        end
        curated = curated + took;
    end
    rois = [reshape(moved, 1, []), existing(~ismember(existingIds, referenceIds))];
    ids = zeros(1, numel(rois));
    for i = 1:numel(rois)
        ids(i) = double(rois{i}.id);
    end
    for i = 1:numel(rois)
        if isfield(rois{i}, "links")
            links = rois{i}.links;
            if iscell(links)
                links = cell2mat(cellfun(@double, links(:)', UniformOutput=false));
            end
            links = double(reshape(links, 1, []));
            links = links(ismember(links, ids));
            if isempty(links)
                rois{i} = rmfield(rois{i}, "links");
            else
                rois{i}.links = num2cell(links);   % a list, also of one
            end
        end
    end
end

function yes = isNone(value)
    % Whether a value is nothing, as Python's falsy None, "" and []
    yes = isempty(value) || (isstring(value) && all(value == ""));
end
