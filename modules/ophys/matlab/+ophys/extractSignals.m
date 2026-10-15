function result = extractSignals(entity, options, context)
%extractSignals Average of each ROI's pixels per frame (frames x ROIs), and of neuropil around it outside every ROI
%
%   Reads the stack a chunk at a time. With excludeOverlaps (dev's
%   excludeRoiOverlaps), pixels in more than one ROI are left out of the
%   ROIs' signals. The neuropil is a ring (neuropilGap pixels from the ROI,
%   neuropilWidth wide), or with neuropilMethod "expansion" dev's (see
%   ophys.internal.expansionNeuropil). With plane 0, each ROI's signal is
%   read from its own plane (its place; the ROIs of the other channels are
%   left out), and the ROIs of a plane are those every ROI and neuropil is
%   reckoned with: the columns are the ROIs in the file's order, whatever
%   their planes. As Python's ophys_methods.extract_signals.
    [~, stacks, every] = ophys.internal.planeStacks(context, entity, options.stack, options);
    [~, ~, frames] = size(stacks{1});
    channel = double(nansen.internal.getField(options, "channel", 1));
    value = context.Project.load(entity, options.rois);
    if every   % the ROIs of the channel used, each on its plane
        document = value;
        rois = ophys.internal.roiList(value);
        rois = rois(cellfun(@(r) nansen.internal.getField(r, "channel", channel) == channel, rois));
    else   % the ROIs of the plane and channel used, when they have places (dev's RoiGroup of several)
        document = nansen.internal.roisAt(value, double(nansen.internal.getField(options, "plane", 1)), channel);
        rois = ophys.internal.roiList(document);
    end
    keep = cellfun(@(r) options.includeRejected || ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), rois);
    rois = rois(keep);
    ids = cell(1, numel(rois));
    places = ones(1, numel(rois));
    for i = 1:numel(rois)
        ids{i} = nansen.internal.getField(rois{i}, "id", i);
        if every
            places(i) = roiPlane(rois{i}, numel(stacks), options.rois);
        end
    end
    signals = nan(frames, numel(rois));
    neuropil = nan(frames, numel(rois));
    counts = zeros(1, numel(stacks));
    for p = 1:numel(stacks)
        columns = find(places == p);
        counts(p) = numel(columns);
        part = document;
        part.rois = rois(columns);
        [planeSignal, planeNeuropil] = planeSignals(stacks{p}, part, options, context, p, numel(stacks));
        signals(:, columns) = planeSignal;
        neuropil(:, columns) = planeNeuropil;
    end
    ophys.internal.saveIf(context, entity, options.output, signals);
    ophys.internal.saveIf(context, entity, options.neuropilOutput, neuropil);
    context.log("%s: signals of %d ROIs in %d frames", ophys.internal.entityName(entity), numel(rois), frames);
    result = struct("rois", numel(rois), "frames", frames, "ids", {ids}, ...
        "meanSignal", {num2cell(ophys.internal.roundTo(mean(signals, 1), 4))}, ...
        "meanNeuropil", {num2cell(ophys.internal.roundTo(mean(neuropil, 1), 4))});
    if every
        result.planes = arrayfun(@(p) struct("plane", p, "rois", counts(p)), 1:numel(stacks), UniformOutput=false);
    end
end

function plane = roiPlane(roi, planes, name)
    % The plane (from 1) of an ROI extracted with every plane: its place, or the one plane of a stack of one
    plane = nansen.internal.getField(roi, "plane", []);
    if isempty(plane) && planes == 1
        plane = 1;
        return
    end
    id = double(nansen.internal.getField(roi, "id", NaN));
    if isempty(plane)
        nansen.internal.throwError("invalid-data", "ROI %d of %s has no plane, so it is of every plane: extract its signals one plane at a time", id, name)
    end
    plane = double(plane);
    if plane < 1 || plane > planes
        nansen.internal.throwError("invalid-data", "ROI %d of %s is of plane %d; the stack has %d", id, name, plane, planes)
    end
end

function [signals, neuropil] = planeSignals(stack, document, options, context, plane, planes)
    % The signals and neuropil (frames x ROIs) of the ROIs of an ROI file in a height x width x frames stack
    [height, width, frames] = size(stack);
    masks = ophys.internal.roiMasks(document, height, width);
    count = numel(masks);
    signals = nan(frames, count);
    neuropil = nan(frames, count);
    union = false(height, width);
    covered = zeros(height, width);
    for i = 1:count
        union = union | masks{i};
        covered = covered + masks{i};
    end
    own = masks;
    if nansen.internal.getField(options, "excludeOverlaps", false)
        own = cellfun(@(m) m & covered == 1, masks, UniformOutput=false);
    end
    if string(nansen.internal.getField(options, "neuropilMethod", "ring")) == "expansion"
        rings = ophys.internal.expansionNeuropil(masks, union, nansen.internal.getField(options, "neuropilExpansionFactor", 4), ...
            nansen.internal.getField(options, "neuropilSeparation", 0));
    else
        rings = cell(1, count);
        for i = 1:count
            rings{i} = ophys.internal.dilate(masks{i}, options.neuropilGap + options.neuropilWidth) ...
                & ~ophys.internal.dilate(masks{i}, options.neuropilGap) & ~union;
        end
    end
    for start = 1:ophys.internal.chunk():frames
        context.checkCancelled();
        stop = min(start + ophys.internal.chunk() - 1, frames);
        flat = reshape(stack.frames(start, stop), height * width, stop - start + 1);
        for i = 1:count
            if any(own{i}, "all")
                signals(start:stop, i) = mean(double(flat(own{i}(:), :)), 1)';
            end
            if any(rings{i}, "all")
                neuropil(start:stop, i) = mean(double(flat(rings{i}(:), :)), 1)';
            end
        end
        context.progress((plane - 1 + stop / frames) / planes, sprintf("frame %d/%d", stop, frames));
    end
end
