function result = extractSignals(entity, options, context)
%extractSignals Average of each ROI's pixels per frame (frames x ROIs), and of neuropil around it outside every ROI
%
%   Reads the stack a chunk at a time. With excludeOverlaps (dev's
%   excludeRoiOverlaps), pixels in more than one ROI are left out of the
%   ROIs' signals. The neuropil is a ring (neuropilGap pixels from the ROI,
%   neuropilWidth wide), or with neuropilMethod "expansion" dev's (see
%   nansen.internal.neuropilMasks); with numNeuropilSlices above 1 it is
%   split in slices around the ROI (nansen.internal.neuropilSlices, dev's
%   splitNeuropilMasks) and the neuropil signal is the mean of the slices'
%   means, as dev's ΔF/F methods take its slices. With plane 0, each ROI's
%   signal is read from its own plane, and with channel 0 (dev's
%   extractSignalsMultiChannel) from its own channel (its place; with one
%   of them, the ROIs of the other planes or channels are left out). The
%   ROIs of a plane and channel are those every ROI and neuropil is
%   reckoned with, and the columns are the ROIs in the file's order,
%   whatever their places. As Python's ophys_methods.extract_signals.
    whole = ophys.internal.openWhole(context, entity, options.stack, options);
    channel = double(nansen.internal.getField(options, "channel", 1));
    plane = double(nansen.internal.getField(options, "plane", 1));
    channels = 1;
    planes = 1;
    if ndims(whole) >= 4
        channels = size(whole, 3);
    end
    if ndims(whole) == 5
        planes = size(whole, 4);
    end
    everyPlane = plane == 0 && ndims(whole) == 5;
    everyChannel = channel == 0;
    plane = max(plane, 1);
    value = context.Project.load(entity, options.rois);
    if everyPlane || everyChannel   % the ROIs of the channel or plane used, if one is, each at its place
        document = value;
        rois = ophys.internal.roiList(value);
        rois = rois(cellfun(@(r) (everyChannel || nansen.internal.getField(r, "channel", channel) == channel) ...
            && (everyPlane || nansen.internal.getField(r, "plane", plane) == plane), rois));
    else   % the ROIs of the plane and channel used, when they have places (dev's RoiGroup of several)
        document = nansen.internal.roisAt(value, plane, channel);
        rois = ophys.internal.roiList(document);
    end
    keep = cellfun(@(r) options.includeRejected || ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), rois);
    rois = rois(keep);
    ids = cell(1, numel(rois));
    places = repmat([max(channel, 1), plane], numel(rois), 1);   % channel, plane
    for i = 1:numel(rois)
        ids{i} = nansen.internal.getField(rois{i}, "id", i);
        if everyChannel
            places(i, 1) = roiPlace(rois{i}, "channel", channels, options.rois);
        end
        if everyPlane
            places(i, 2) = roiPlace(rois{i}, "plane", planes, options.rois);
        end
    end
    first = ophys.internal.pick(whole, options.stack, max(channel, 1), plane);   % invalid-options for a channel or plane it has not
    [~, ~, frames] = size(first);
    signals = nan(frames, numel(rois));
    neuropil = nan(frames, numel(rois));
    taken = unique(places, "rows");   % channel by channel, plane by plane
    for k = 1:size(taken, 1)
        columns = find(places(:, 1) == taken(k, 1) & places(:, 2) == taken(k, 2))';
        part = document;
        part.rois = rois(columns);
        stack = ophys.internal.pick(whole, options.stack, taken(k, 1), taken(k, 2));
        [placeSignal, placeNeuropil] = placeSignals(stack, part, options, context, k, size(taken, 1));
        signals(:, columns) = placeSignal;
        neuropil(:, columns) = placeNeuropil;
    end
    ophys.internal.saveIf(context, entity, options.output, signals);
    ophys.internal.saveIf(context, entity, options.neuropilOutput, neuropil);
    context.log("%s: signals of %d ROIs in %d frames", ophys.internal.entityName(entity), numel(rois), frames);
    result = struct("rois", numel(rois), "frames", frames, "ids", {ids}, ...
        "meanSignal", {num2cell(ophys.internal.roundTo(mean(signals, 1), 4))}, ...
        "meanNeuropil", {num2cell(ophys.internal.roundTo(mean(neuropil, 1), 4))});
    if everyChannel
        result.channels = arrayfun(@(c) struct("channel", c, "rois", nnz(places(:, 1) == c)), 1:channels, UniformOutput=false);
    end
    if everyPlane
        result.planes = arrayfun(@(p) struct("plane", p, "rois", nnz(places(:, 2) == p)), 1:planes, UniformOutput=false);
    end
end

function place = roiPlace(roi, axis, count, name)
    % The plane or channel (axis, from 1) of an ROI extracted with every one of them: its place, or the one of a stack of one
    place = nansen.internal.getField(roi, axis, []);
    if isempty(place) && count == 1
        place = 1;
        return
    end
    id = double(nansen.internal.getField(roi, "id", NaN));
    if isempty(place)
        nansen.internal.throwError("invalid-data", "ROI %d of %s has no %s, so it is of every %s: extract its signals one %s at a time", ...
            id, name, axis, axis, axis)
    end
    place = double(place);
    if place < 1 || place > count
        nansen.internal.throwError("invalid-data", "ROI %d of %s is of %s %d; the stack has %d", id, name, axis, place, count)
    end
end

function [signals, neuropil] = placeSignals(stack, document, options, context, step, steps)
    % The signals and neuropil (frames x ROIs) of the ROIs of an ROI file in a height x width x frames stack
    [height, width, frames] = size(stack);
    masks = ophys.internal.roiMasks(document, height, width);
    count = numel(masks);
    signals = nan(frames, count);
    neuropil = nan(frames, count);
    covered = zeros(height, width);
    for i = 1:count
        covered = covered + masks{i};
    end
    own = masks;
    if nansen.internal.getField(options, "excludeOverlaps", false)
        own = cellfun(@(m) m & covered == 1, masks, UniformOutput=false);
    end
    rings = nansen.internal.neuropilMasks(masks, options);   % the core's, as rois.neuropil shows it
    slices = double(nansen.internal.getField(options, "numNeuropilSlices", 1));
    parts = cell(1, count);
    for i = 1:count
        pieces = nansen.internal.neuropilSlices(rings{i}, masks{i}, slices);
        parts{i} = pieces(cellfun(@(p) any(p, "all"), pieces));
    end
    for start = 1:ophys.internal.chunk():frames
        context.checkCancelled();
        stop = min(start + ophys.internal.chunk() - 1, frames);
        flat = reshape(stack.frames(start, stop), height * width, stop - start + 1);
        for i = 1:count
            if any(own{i}, "all")
                signals(start:stop, i) = mean(double(flat(own{i}(:), :)), 1)';
            end
            if ~isempty(parts{i})   % the mean of the slices' means
                total = zeros(stop - start + 1, 1);
                for k = 1:numel(parts{i})
                    total = total + mean(double(flat(parts{i}{k}(:), :)), 1)';
                end
                neuropil(start:stop, i) = total / numel(parts{i});
            end
        end
        context.progress((step - 1 + stop / frames) / steps, sprintf("frame %d/%d", stop, frames));
    end
end
